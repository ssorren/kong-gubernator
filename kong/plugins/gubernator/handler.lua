local http              = require("resty.http")
local json_decode       = require("cjson.safe").decode
local json_encode       = require("cjson.safe").encode
local timer             = require("resty.timerng")
local jwt               = require "kong.plugins.jwt.jwt_parser"
local md5               = require "resty.md5"
local to_hex            = require "resty.string".to_hex
local kong              = kong

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
    for i = 1, #configs do
        local config = configs[i]
        for j = 1, #config.rules do
            local rule = config.rules[j]
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

    for i = 1, #body.responses do
        local response = body.responses[i]
        if response.status == "OVER_LIMIT" or tonumber(response.remaining) < 1 then
            kong.response.add_header("X-Kong-Limit-Exceeded", throttle_requests.all[i].name)
            return kong.response.exit(429)
        end
    end
    for i = 1, #throttle_requests.by_request do
        throttle_requests.by_request[i].hits = "1"
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
    for i = 1, #conf.rules do
        if conf.rules[i].limit_type == "TOKENS" then
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
    if err3 then
        kong.log("Body error: ", err)
        return nil, err3
    end
    local _, err4 = client:set_keepalive(100000)
    if err4 then
        kong.log("Failed to keep socket alive: ", err4)
    end
    return body, nil
end

local function to_set(v)
    if not v then return {} end
    local set = {}
    for i = 1, #v do
        set[v[i]] = true
    end
    return set
end

function helper:async_call_rate_limiter(conf, throttle_requests)
    local function consume()
        local _, err = helper:call_rate_limiter(conf, throttle_requests)
        if err then
            kong.log("Error consuming throttle requests: ", err)
        end
    end
    local _, err = request_timer:at(0, consume)
    if err then
        kong.log("Error scheduling requests: ", err)
    end
end

-- we may need to override the key to be used for rate limiting
-- for instance, if we limiting off of a group/team and the user ha multiple teams
-- we would need to ensure that the key used in gubernator matches the override returned
local function key_for_override(original_key, override, candidate)
    if override.throttle_key_source == "INHERIT" then
        return (candidate or override.match_expr)
    end
    return original_key
end

function helper:override_matches(input, rule, override, token)
    local input_rule = override
    if override.throttle_key_source == "INHERIT" then 
        input_rule = rule
    end
    local input_values = ensure_list(helper:rule_input_value(input_rule, token))
    
    -- Early exit if no input values
    if not input_values or #input_values == 0 then
        return false, input
    end
    
    local match_expr = override.match_expr
    local match_type = override.match_type
    
    -- prioritize exact matches
    local input_set = to_set(input_values)
    if input_set[match_expr] then
        return true, key_for_override(input, override, nil)
    end
    
    -- Early exit if not prefix matching
    if match_type ~= "PREFIX" then
        return false, input
    end
    
    -- Optimize prefix matching with cached length
    local match_expr_len = #match_expr
    for i = 1, #input_values do
        local value = input_values[i]
        if value and #value >= match_expr_len and value:sub(1, match_expr_len) == match_expr then
            return true, key_for_override(input, override, value)
        end
    end
    return false, input
end

function helper:find_override(input, rule, token)
    local overrides = rule.overrides
    if not overrides or #overrides == 0 then
        return nil, input
    end
    
    -- Use numeric indexing for better performance
    for i = 1, #overrides do
        local override = overrides[i]
        local ok, input_override = helper:override_matches(input, rule, override, token)
        if ok then
            return override, input_override
        end
    end
    return nil, input
end

local input_retriever = {
    ["CONSUMER_ID"] = function(rule, token)
        local consumer = kong.client.get_consumer()
        if consumer then
            return consumer.id
        else
            return nil
        end
    end,
    ["HEADER"] = function(rule, token) return kong.request.get_header(rule.throttle_key_name) end,
    ["CONSUMER_GROUP_NAME"] = function(input, rule, token) 
        local groups = kong.client.get_consumer_groups()
        if groups and #groups > 0 then
            local names = {}
            for i = 1, #groups do
                names[i] = groups[i].name
            end
            return groups
        end
        return nil
    end,
    ["JWT_SUBJECT"] = function(rule, token) 
        if token then
            return token.claims.sub
        end
        return nil
     end,
    ["JWT_CLAIM"] = function(rule, token)
        if token then
            return token.claims[rule.throttle_key_name]
        end
        return nil
    end,
}

function helper:rule_input_value(rule, token)
    return input_retriever[rule.throttle_key_source](rule, token)
end

local function has_request_method(rule, request_method)
    local methods = rule.methods
    if not methods then
        return false
    end
    for i = 1, #methods do
        if methods[i] == request_method then
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
    
    -- Cache request method to avoid repeated calls
    local request_method = kong.request.get_method()
    
    for _, rule in ipairs(conf.rules) do
        if not has_request_method(rule, request_method) then
            goto continue
        end
        
        local input_value = helper:rule_input_value(rule, token)
        local original_input = input_value
        
        -- Optimize table handling: check if it's a table and has elements in one condition
        if type(original_input) == "table" and #original_input > 0 then
            original_input = original_input[1]
        end
        
        -- Early exit only if we have no input at all
        if not original_input or (type(original_input) == "string" and #original_input == 0) then
            goto continue  -- Skip this rule instead of returning nil
        end

        local limit = rule.limit
        local duration_seconds = rule.duration_seconds

        -- Check to see if there are overrides that match this request
        local override, key = helper:find_override(original_input, rule, token)
        if override then
            limit = override.limit
            duration_seconds = override.duration_seconds
        end
        
        -- Optimize logging by using table.concat instead of multiple concatenations
        kong.log.debug("throttling on input key: ", rule.throttle_key_prefix, ":", key, " limit: ", limit, "/", duration_seconds, " seconds")
        
        local req = {
            name = rule.name,
            unique_key = hash(rule.throttle_key_prefix, rule.limit_type, key),
            hits = hits,
            limit = limit,
            duration = duration_seconds * 1000,
            behavior = 34,
        }
        
        -- Use direct assignment instead of table.insert for better performance
        res.all[#res.all + 1] = req
        
        if rule.limit_type == "REQUESTS" then
            res.by_request[#res.by_request + 1] = req
        else
            res.by_token[#res.by_token + 1] = req
        end
        
        ::continue::
    end

    -- Return nil only if no rules were processed successfully
    if #res.all == 0 then
        return nil
    end

    return res
end

return GubernatorHandler
