local http              = require("resty.http")
local json_decode       = require("cjson.safe").decode
local json_encode       = require("cjson.safe").encode
local timer             = require("resty.timerng")
local jwt               = require "kong.plugins.jwt.jwt_parser"
local md5               = require "resty.md5"
local to_hex            = require "resty.string".to_hex

local GubernatorHandler = {
    PRIORITY = 910,
    VERSION = "0.0.1",
}

local helper            = {}
local request_timer

local READ_BODY_METHODS = {
    DELETE = true, -- this is a stretch, but lets allow it
    PATCH = true,
    POST = true,
    PUT = true,
}

local function hash(...)
    local digest = md5:new()
    digest:update(table.concat({...}, ":"))
    return to_hex(digest:final())
end

local function ensure_list(value)
    if not value then
        return value
    end
    if type(value) == "table" then
        return value
    end
    return { value }
end

local function sort_overrides(a, b)
    -- we're prioritizing high throughput in overrides
    return (a.limit / a.duration_seconds) > (b.limit / b.duration_seconds)
end

function GubernatorHandler:init_worker()
    if request_timer == nil then
        request_timer = timer.new({})
        request_timer:start()
    end
    return true
end

function GubernatorHandler:configure(configs)
    if not configs then
        return true
    end
    for _, config in ipairs(configs) do
        for _, rule in ipairs(config.rules) do
            if rule.overrides then
                table.sort(rule.overrides, sort_overrides)
            end
        end
    end
    return true
end

function GubernatorHandler:access(conf)
    local throttle_requests = helper:get_throttle_requests(conf, helper:get_jwt_token(), 0)
    if not throttle_requests then
        return kong.response.exit(400)
    end
    local result, err = helper:call_rate_limiter(conf, throttle_requests.all)
    if err then
        kong.log("Error calling gubernator: ", err)
        return
    end
    local body, err2 = json_decode(result)
    if err2 then
        kong.log("Error parsing gubernator response: ", err)
        return
    end

    for i, response in ipairs(body.responses)
    do
        if response.status == "OVER_LIMIT" or tonumber(response.remaining) < 1 then
            kong.response.add_header("X-Kong-Limit-Exceeded", throttle_requests.all[i].name)
            return kong.response.exit(429)
        end
    end
    for _, rule in ipairs(throttle_requests.by_request)
    do
        rule.hits = "1"
    end

    helper:async_call_rate_limiter(conf, throttle_requests.by_request)
end

function GubernatorHandler:body_filter(conf)
    local status = kong.response.get_status()
    if not status or status < 200 or status >= 300 then
        return
    end
    if not READ_BODY_METHODS[kong.request.get_method()] then
        return
    end
    
    local has_token_rules = false
    for _, rule in ipairs(conf.rules) do
        if rule.limit_type == "TOKENS" then
            has_token_rules = true
            break
        end
    end
    -- if we don't have any token rules, it's safe to return 
    if not has_token_rules then
        return
    end

    local body = kong.response.get_raw_body()
    if not body then
        return
    end
    local body_table, err = json_decode(body)
    if err then
        kong.log("Error parsing body: ", err)
        kong.log("Error parsing body status: ", status)
        return
    end

    if body_table.usage and body_table.usage.completion_tokens then
        local throttle_requests = helper:get_throttle_requests(conf, helper:get_jwt_token(),
            body_table.usage.completion_tokens)
        if not throttle_requests or #throttle_requests.by_token == 0 then
            return
        end
        helper:async_call_rate_limiter(conf, throttle_requests.by_token)
    end
end

function helper:get_jwt_token()
    local token = kong.request.get_header("Authorization")
    if token then
        local decoded_jwt, err = jwt:new(token:gsub("Bearer ", "", 1))
        if err then
            -- kong.response.exit(401, { message = "Invalid JWT" })
            return nil
        end
        return decoded_jwt
    end
end

function helper:call_rate_limiter(conf, throttle_requests)
    local client = http:new()
    local ok, err = client:connect({
        scheme = conf.gubernator_protocol,
        host = conf.gubernator_host,
        port = conf.gubernator_port,
        pool_size = 30,
    })

    if not ok then
        kong.log("Conenct error: ", err)
        return nil, err
    end
    local hits = json_encode({ requests = throttle_requests })
    local res, err2 = client:request({
        version = 1.1,
        method = "POST",
        path = "/v1/GetRateLimits",
        body = hits,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })

    if err2 then
        kong.log("Result error: ", err)
        return nil, err2
    end

    local body, err3 = res:read_body()
    if not body then
        kong.log("Body error: ", err)
        return nil, err3
    end
    local _, err4 = client:set_keepalive(100000)
    if err4 then
        kong.log("Failed to keep socket alive: ", err4)
    end
    return body, nil
end

function helper:async_call_rate_limiter(conf, throttle_requests)
    local function consume()
        local _, err = helper:call_rate_limiter(conf, throttle_requests)
        if err then
            kong.log("Error consuming throttle requests: ", err)
        end
    end
    local _, err = request_timer:at(0.05, consume)
    if err then
        kong.log("Error scheduling requests: ", err)
    end
end

function helper:override_matches(input, override, token)
    local input_values = ensure_list(helper:override_input_value(input, override, token))
    for _, value in ipairs(input_values) do
        local match_expr = override.match_expr
        if match_expr == value or 
            (override.match_type == "PREFIX" and value 
            and #value >= #match_expr and value:sub(1, #match_expr) == match_expr)  then
                -- we may need to override the key to be used for rate limiting
                -- for instance, if we limiting off of a group/team and the user ha multiple teams
                -- we would need to ensure that the key used in gubernator matches the override returned
                if override.input_source == "INHERIT" then
                    return true, value
                end
                return true, input
        end
    end
    return false
end

function helper:find_override(input, overrides, token)
    if not overrides or #overrides == 0 then
        return input
    end

    input = ensure_list(input)
    for _, override in ipairs(overrides) do
        local ok, input_override = helper:override_matches(input, override, token)
        if ok then
            return override, input_override
        end
    end
    return nil, input
end

local input_retriever = {
    ["INHERIT"] = function(input, rule, token) return input end,
    ["CONSUMER_ID"] = function(input, rule, token)
        local consumer = kong.client.get_consumer()
        if consumer then
            return consumer.id
        else
            return nil
        end
    end,
    ["HEADER"] = function(input, rule, token) return kong.request.get_header(rule.input_key_name) end,
    ["CONSUMER_GROUP_NAME"] = function(input, rule, token) 
        local groups = kong.client.get_consumer_groups()
        if groups and #groups then
            local names = kong.table(#groups)
            for i, g in ipairs(groups) do
                table.insert(names, i, g.name)
            end
        end
        return nil
    end,
    ["JWT_SUBJECT"] = function(input, rule, token) 
        if token then
            return token.claims.sub
        end
        return nil
     end,
    ["JWT_CLAIM"] = function(input, rule, token)
        if token then
            return token.claims[rule.input_key_name]
        end
        return nil
    end,
}

function helper:override_input_value(input, override, token)
    return input_retriever[override.input_source](input, override, token)
end

function helper:rule_input_value(rule, token)
    return input_retriever[rule.input_source](nil, rule, token)
end

local function has_request_method(rule, request_method)
    for _, v in ipairs(rule.methods)
    do
        if v == request_method then
            return true
        end
    end
    return false
end

function helper:get_throttle_requests(conf, token, hits)
    local res = {
        by_request = {},
        by_token = {},
        all = {},
    }
    for _, rule in ipairs(conf.rules)
    do
        if not has_request_method(rule, kong.request.get_method()) then
            goto continue
        end
        local input_value = helper:rule_input_value(rule, token)
        -- it is possible that input is a list (multiple values for a claim etc.).
        -- if so, we'll just grab the first in the list for now. we may want to come up with more deterministic behavior
        if input_value and type(input_value) == "table" and #input_value > 0 then
            input_value = input_value[1]
        end
        if not input_value or #input_value == 0 then
            return nil
        end

        local limit = rule.limit
        local duration_seconds = rule.duration_seconds

        -- Check to see if there are overrides that match this request
        local override, key = helper:find_override(input_value, rule.overrides, token)
        if override then
            limit = override.limit
            duration_seconds = override.duration_seconds
        end
        
        local req = {
            name = rule.name,
            unique_key = hash(rule.rate_limit_key_prefix, rule.limit_type, key),
            hits = hits,
            limit = limit,
            duration = duration_seconds * 1000,
            behavior = 34,
        }
        table.insert(res.all, req)
        if rule.limit_type == "REQUESTS" then
            table.insert(res.by_request, req)
        else
            table.insert(res.by_token, req)
        end
        ::continue::
    end

    return res
end

return GubernatorHandler
