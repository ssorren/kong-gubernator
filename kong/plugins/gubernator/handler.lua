local http  = require("resty.http")
local cjson = require("cjson.safe")
local timer = require("resty.timerng")
local jwt = require "kong.plugins.jwt.jwt_parser"

local GubernatorHandler = {
    PRIORITY = 910,
    VERSION = "0.0.1",
}

local helper = {}
local timer_sys


function helper:get_timer()
    if timer_sys == nil then
        timer_sys = timer.new({})
        timer_sys:start()
    end
    return timer_sys
end

function helper:get_jwt_token()
    local token = kong.request.get_header("Authorization")
    if token then
        local decoded_jwt, err = jwt:new(token:gsub("Bearer ", "", 1))
        if err then
            -- kong.response.exit(401, { message = "Invalid JWT" })
            return nil
        end
        -- kong.response.add_header("X-Department", decoded_jwt.claims.department)
        -- kong.response.add_header("X-Sub", decoded_jwt.claims.sub)
        return decoded_jwt
    end
end

function helper:call_rate_limiter(conf, throttle_requests)    
    local hits =  cjson.encode({requests = throttle_requests})
    local url = conf.gubernator_protocol.."://"..conf.gubernator_host..":"..conf.gubernator_port.."/v1/GetRateLimits"
    return http.new():request_uri(url, {
        method = "POST",
        body = hits,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })
end

-- Function to find the best matching override for the header value.
-- Prioritizes exact matches first.
-- If no exact match, finds the longest prefix match.
-- Assumes keys are prefixes for partial matches
-- If multiple matches of the same length, returns the first one encountered after sorting by length descending.
function helper:find_override(input, overrides, token)
    if not overrides or #overrides == 0 then
        return nil
    end
    -- First, check for exact match
    for _, override in ipairs(overrides)
    do
        local input_value = helper:override_input_value(input, override, token)
        if input_value and override.match_expr == input_value then
            return override
        end
    end
    -- No exact match, find longest prefix match
    -- Sort keys by length descending
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

    -- Iterate through sorted keys to find the longest prefix
    for _, override in ipairs(sorted)
    do
        local input_value = helper:override_input_value(input, override, token)
        local key = override.match_expr
        if input_value and #input_value >= #key and input_value:sub(1, #key) == key then
            return override
        end
    end

    -- No match found
    return nil
end

function helper:async_call_rate_limiter(conf, throttle_requests)
    local function consume() 
        local _, err = helper:call_rate_limiter(conf, throttle_requests)
        if err then
            kong.log("Error consuming throttle requests: ", err)
        end
    end
    local _, err = helper:get_timer():at(0.01, consume)
    if err then
        kong.log("Error scheduling requests: ", err)
    end
end

function GubernatorHandler:access(conf)
    local throttle_requests = helper:get_throttle_requests(conf, helper:get_jwt_token(), 0)
    if not throttle_requests then
        return kong.response.exit(400)
    end
    local res, err = helper:call_rate_limiter(conf, throttle_requests.all)
    if err then
        kong.log("Error calling gubernator: ", err)
        return
    end
    local responses, err = cjson.decode(res.body)
    if err then
        kong.log("Error parsing gubernator response: ", err)
        return
    end
    for i, res in ipairs(responses.responses)
    do
        if res.status == "OVER_LIMIT" or tonumber(res.remaining) < 1 then
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
        local throttle_requests = helper:get_throttle_requests(conf, helper:get_jwt_token(), body_table.usage.completion_tokens)
        if not throttle_requests or #throttle_requests.by_token == 0 then
            return
        end
        helper:async_call_rate_limiter(conf, throttle_requests.by_token)
        kong.log("response ctx:", cjson.encode(kong.ctx))
    end
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

function helper:input_value(rule, token)
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
        local input_value = helper:input_value(rule, token)
        if not input_value then
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
            unique_key = rule.rate_limit_key_prefix..":"..rule.limit_type..":"..input_value,
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
