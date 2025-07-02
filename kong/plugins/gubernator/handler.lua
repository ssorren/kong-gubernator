local http  = require("resty.http")
local cjson = require("cjson.safe")
local timer = require("resty.timerng")

local GubernatorHandler = {
    PRIORITY = 1,
    VERSION = "0.0.1",
}

local helper = {}
local timer_sys

-- do
--     timer_sys = timer.new({})
--     timer_sys:start()
-- end

function get_timer()
    if timer_sys == nil then
        timer_sys = timer.new({})
        timer_sys:start()
    end
    return timer_sys
end

function callRateLimiter(throttle_requests)    
    local hits =  cjson.encode({requests = throttle_requests})
    return http.new():request_uri("http://localhost:1050/v1/GetRateLimits", {
        method = "POST",
        body = hits,
        headers = {
            ["Content-Type"] = "application/json",
        },
    })
end

function asyncCallRateLimiter(throttle_requests, timer)
    local function consume() 
        local res, err = callRateLimiter(throttle_requests)
        if err then
            kong.log("Error consumeing throttle requests: ", err)
        end
    end
    local name, err = get_timer():at(0.1, consume)
    if err then
        kong.log("Error scheduling requests: ", err2)
    end
end

function GubernatorHandler:access(conf)
    local throttle_requests = helper:get_throttle_requests(conf, 0)
    if not throttle_requests then
        return kong.response.exit(400)
    end
    local res, err = callRateLimiter(throttle_requests.all)
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
            kong.response.add_header("x-kong-limit-exceeded", throttle_requests.all[i].name)
            return kong.response.exit(429)
        end
    end
    for _, rule in ipairs(throttle_requests.by_request)
    do
        rule.hits = "1"
    end
    
    asyncCallRateLimiter(throttle_requests.by_request)
end

function GubernatorHandler:body_filter(conf)
    local status = kong.response.get_status()
    if not status or status < 200 or status >= 300 then
        return
    end
    local body = kong.response.get_raw_body()
    local body_table, err = cjson.decode(body)
    if err then
        kong.log("Error parsing body: ", err)
        return
    end

    if body_table.usage and body_table.usage.completion_tokens then
        local throttle_requests = helper:get_throttle_requests(conf, body_table.usage.completion_tokens)
        if not throttle_requests or #throttle_requests.by_token == 0 then
            return
        end
        asyncCallRateLimiter(throttle_requests.by_token)
        kong.log("response ctx:", cjson.encode(kong.ctx))
    end
end

function helper:get_throttle_requests(conf, hits)
    local res = {
        by_request = {},
        by_token = {},
        all = {},
    }
    for _, rule in ipairs(conf.rules)
    do
        local header_value = kong.request.get_header(rule.header_name)
        if not header_value then
            return nil
        end

        local req = {
            name = rule.name,
            unique_key = rule.key_prefix..":"..rule.limit_type..":"..header_value,
            hits = hits,
            limit = rule.limit,
            duration = rule.duration_seconds * 1000,
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

function helper:http_client()
    if self.httpc == nil then
       self.httpc = http.new()
    end
    return self.httpc
end

   
return GubernatorHandler
