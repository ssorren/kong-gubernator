local http              = require("resty.http")
local cjson             = require("cjson.safe")
local timer             = require("resty.timerng")
local jwt               = require "kong.plugins.jwt.jwt_parser"
local sha1 = require "resty.sha1"
local to_hex = require "resty.string".to_hex

local GubernatorHandler = {
    PRIORITY = 910,
    VERSION = "0.0.1",
}

local helper            = {}
local request_timer


local function hash(key)
    local digest = sha1:new()
    digest:update(key)
    return to_hex(digest:final())
end

function GubernatorHandler:init_worker()
    if request_timer == nil then
        request_timer = timer.new({})
        request_timer:start()
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
    local body, err2 = cjson.decode(result.body)
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
    local body = kong.response.get_raw_body()
    if not body then
        return
    end
    local body_table, err = cjson.decode(body)
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
        kong.log("response ctx:", cjson.encode(kong.ctx))
    end
end

function helper:ensure_list(value)
    if not value then
        return value
    end
    if type(value) == "table" then
        return value
    end
    return { value }
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
    local hits = cjson.encode({ requests = throttle_requests })
    local url = conf.gubernator_protocol .. "://" .. conf.gubernator_host ..
        ":" .. conf.gubernator_port .. "/v1/GetRateLimits"
    return http.new():request_uri(url, {
        method = "POST",
        body = hits,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })
end

function helper:async_call_rate_limiter(conf, throttle_requests)
    local function consume()
        local _, err = helper:call_rate_limiter(conf, throttle_requests)
        if err then
            kong.log("Error consuming throttle requests: ", err)
        end
    end
    local _, err = request_timer:at(0.01, consume)
    if err then
        kong.log("Error scheduling requests: ", err)
    end
end

local function sort_overrides(a, b)
    -- we're prioritizing high throughput in overrides
    return (a.limit / a.duration_seconds) > (b.limit / b.duration_seconds)
end


function helper:find_override_exact_matches(input, overrides, token)
    local matches = {}
    for _, override in ipairs(overrides)
    do
        local input_values = helper:ensure_list(helper:override_input_value(input, override, token))
        if not input_values or #input_values == 0 then
            goto continue
        end
        for _, override_input in ipairs(input_values)
        do
            if override_input and override.match_expr == override_input then
                table.insert(matches, override)
            end
        end
        ::continue::
    end

    if #matches > 0 then
        table.sort(matches, sort_overrides)
        return matches[1]
    end
    return nil
end

function helper:find_prefix_match(input, overrides, token)
    local sorted = {}
    for _, override in ipairs(overrides)
    do
        if override.match_type == "PREFIX" then
            table.insert(sorted, override)
        end
    end
    if #sorted == 0 then
        return nil -- no prefix matchers available, safe ot return
    end
    table.sort(sorted, function(a, b) return #a.match > #b.match end)

    local prefix_matches = {}
    -- Iterate through sorted keys to find the longest prefix
    for _, override in ipairs(sorted)
    do
        local input_values = helper:ensure_list(helper:override_input_value(input, override, token))
        local key = override.match_expr
        for _, input_value in ipairs(input_values)
        do
            if input_value and #input_value >= #key and input_value:sub(1, #key) == key then
                table.insert(prefix_matches, override)
                break
            end
        end
    end
    if #prefix_matches == 0 then
        return nil
    end
    table.sort(prefix_matches, sort_overrides)
    return prefix_matches[1]
end

-- Function to find the best matching override for the header value.
-- Prioritizes exact matches first.
-- If no exact match, finds the longest prefix match.
-- Assumes keys are prefixes for partial matches
-- If multiple matches of the same length, returns the first one encountered after sorting by length descending.
-- if input defined has multiple values (i.e. multiple role claims), and there are multiple overrides that match,
-- the override with the most throughput is returned
function helper:find_override(input, overrides, token)
    if not overrides or #overrides == 0 then
        return nil
    end

    if type(input) == "string" then
        input = { input }
    end
    local exact_match = helper:find_override_exact_matches(input, overrides, token)
    if exact_match then
        return exact_match
    end
    -- No exact match, find longest prefix match
    return helper:find_prefix_match(input, overrides, token)
end

function helper:override_input_value(input, override, token)
    if override.input_source == "INHERIT" then
        return input
    end

    if override.input_source == "HEADER" then
        return kong.request.get_header(override.input_key_name)
    end

    if override.input_source == "JWT_SUBJECT" then
        return token.claims.sub
    end

    if override.input_source == "JWT_CLAIM" then
        return token.claims[override.input_key_name]
    end
    return nil
end

function helper:rule_input_value(rule, token)
    if rule.input_source == "HEADER" then
        return kong.request.get_header(rule.input_key_name)
    end
    if not token then
        kong.response.exit(401, { message = "Invalid JWT" })
    end
    if rule.input_source == "JWT_SUBJECT" then
        return token.claims.sub
    end
    if rule.input_source == "JWT_CLAIM" then
        return token.claims[rule.input_key_name]
    end
end

function helper:get_throttle_requests(conf, token, hits)
    local res = {
        by_request = {},
        by_token = {},
        all = {},
    }
    for _, rule in ipairs(conf.rules)
    do
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
        local override = helper:find_override(input_value, rule.overrides, token)
        if override then
            limit = override.limit
            duration_seconds = override.duration_seconds
        end
        
        local req = {
            name = rule.name,
            unique_key = rule.rate_limit_key_prefix .. ":" .. rule.limit_type .. ":" .. hash(input_value),
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
    end

    return res
end

return GubernatorHandler
