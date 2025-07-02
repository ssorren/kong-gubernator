/*
	A "hello world" plugin in Go,
	which reads a request header and sets a response header.
*/

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/Kong/go-pdk"
	"github.com/Kong/go-pdk/server"
	"github.com/gubernator-io/gubernator/v2"
	"github.com/sirupsen/logrus"
)

var Version = "0.2"
var Priority = 1
var throttler gubernator.V1Client

type Config struct {
	Message               string         `json:"message"`
	GlobalLimit           int            `json:"global_limit"`
	GlobalDurationSeconds int            `json:"global_duration_seconds"`
	Rules                 []ThrottleRule `json:"rules"`
}

type ThrottleRule struct {
	Name            string `json:"name"`
	HeaderName      string `json:"header_name"`
	KeyPrefix       string `json:"key_prefix"`
	Limit           int    `json:"limit"`
	DurationSeconds int    `json:"duration_seconds"`
	LimitType       string `json:"limit_type"`
}

type RequestsByType struct {
	Requests []*gubernator.RateLimitReq
	Tokens   []*gubernator.RateLimitReq
	All      []*gubernator.RateLimitReq
}

func New() any {
	return &Config{}
}

func main() {
	daemon := setupThrottlingDaemon()
	server.StartServer(New, Version, Priority)
	if daemon != nil {
		daemon.Close()
	}
}

func setupThrottlingDaemon() *gubernator.Daemon {
	if !flag.Parsed() {
		flag.Parse()
	}
	if flag.Lookup("dump").Value.String() == "true" {
		return nil
	}

	configFileReader, err := os.Open("/etc/kong/gubernator.conf")
	if err != nil {
		log.Printf("err opening config file: %v", err)
	}
	daemonConfig, err := gubernator.SetupDaemonConfig(logrus.StandardLogger(), configFileReader)
	if err != nil {
		log.Printf("error setting up config: %v", err)
	}
	daemon, err := gubernator.SpawnDaemon(context.Background(), daemonConfig)
	if err != nil {
		log.Printf("while spawning daemon: %v", err)
	}

	throttler, err = gubernator.DialV1Server(daemonConfig.GRPCListenAddress, daemonConfig.ClientTLS())
	if err != nil {
		log.Printf("while retrieving throttler client: %v", err)
	}
	return daemon
}

func (conf Config) Access(kong *pdk.PDK) {
	host, err := kong.Request.GetHeader("host")
	if err != nil {
		kong.Log.Err("Error reading 'host' header: %s", err.Error())
	}
	hits := int64(1)
	message := conf.Message
	if message == "" {
		message = "hello"
	}
	kong.Response.SetHeader("x-hello-from-go", fmt.Sprintf("Go says %s to %s", message, host))

	if requests, ok := conf.genRateLimitReq(kong); !ok {
		kong.Response.ExitStatus(400)
		return
	} else {
		then := time.Now()
		responses, err := throttler.GetRateLimits(context.Background(), &gubernator.GetRateLimitsReq{
			Requests: requests.All,
		})
		kong.Response.SetHeader("x-gubernation-latency", fmt.Sprintf("%v", time.Since(then)))
		if err == nil {
			for _, res := range responses.GetResponses() {
				if res.GetStatus() == gubernator.Status_OVER_LIMIT || res.Remaining < hits {
					kong.Response.ExitStatus(429)
					return
				}
			}
			go consume(hits, requests.Requests)
		} else {
			kong.Response.Exit(500, []byte(err.Error()), nil)
		}
	}
}

func (conf Config) DummyResponse(kong *pdk.PDK) {
	conf.processResponse(kong)
}

func (conf Config) processResponse(kong *pdk.PDK) {
	// hits := int64(1)

	// serviceResponse := kong.Response
	// source, _ := serviceResponse.GetSource()
	// kong.Response.SetHeader("x-governed-source", source)

	// body, _ := kong.ServiceResponse.GetRawBody()

	// out := new(kong_plugin_protocol.RawBodyResult)
	// kong.ServiceResponse.Ask(`kong.service.response.get_raw_body`, nil, out)

	// kong.Response.SetHeader("x-governed-len", fmt.Sprintf("%v", len(body)))
	// log.Printf("ServiceResponse.Body: %s", body)
	// kong.Response.Exit(200, []byte(out.GetContent()), nil)
	// if status, err := serviceResponse.GetStatus(); err != nil || status < 200 || status >= 300 {
	// 	return
	// }

	// if data, err := serviceResponse.AskString(`kong.service.response.get_raw_body`, nil); err == nil {
	// 	_, ok := conf.genRateLimitReq(kong)
	// 	if !ok {
	// 		return
	// 	}
	// 	var jsonData any
	// 	json.Unmarshal([]byte(data), &jsonData)
	// 	kong.Response.SetHeader("x-governed-parsed", string(data))
	// 	if res, err := jsonpath.JsonPathLookup(jsonData, "$.usage.completion_tokens"); err != nil {
	// 		// tokensUsed := int64(res.(int))
	// 		kong.Response.SetHeader("x-governed-tokens", fmt.Sprintf("%v", res))
	// 		// go consume(int64(res.(int)), requests.Tokens)
	// 	}
	// }
}

func consume(hits int64, requests []*gubernator.RateLimitReq) {
	for _, r := range requests {
		r.Hits = hits
	}
	throttler.GetRateLimits(context.Background(), &gubernator.GetRateLimitsReq{
		Requests: requests,
	})
}

func (conf Config) genRateLimitReq(kong *pdk.PDK) (RequestsByType, bool) {

	res := RequestsByType{
		Requests: make([]*gubernator.RateLimitReq, 0, len(conf.Rules)),
		Tokens:   make([]*gubernator.RateLimitReq, 0, len(conf.Rules)),
	}

	for _, rule := range conf.Rules {
		if rule.Limit >= 0 {
			headerValue, err := kong.Request.GetHeader(rule.HeaderName)
			if err != nil || len(headerValue) == 0 {
				return RequestsByType{}, false
			}
			req := &gubernator.RateLimitReq{
				Name:      rule.Name,
				UniqueKey: fmt.Sprintf("%s:%s", rule.KeyPrefix, headerValue),
				Hits:      0,
				Limit:     int64(rule.Limit),
				Duration:  int64(rule.DurationSeconds) * gubernator.Second,
				Algorithm: gubernator.Algorithm_LEAKY_BUCKET,
				Behavior:  gubernator.Behavior_GLOBAL | gubernator.Behavior_DRAIN_OVER_LIMIT,
			}
			res.All = append(res.All, req)
			switch rule.LimitType {
			case "REQUESTS":
				res.Requests = append(res.Requests, req)
			case "TOKENS":
				res.Tokens = append(res.Tokens, req)
			}
		}
	}

	if conf.GlobalLimit >= 0 {
		key := ""
		if route, err := kong.Router.GetRoute(); err == nil {
			key = route.Id
		}
		res.Requests = append(res.Requests, &gubernator.RateLimitReq{
			Name:      "global",
			UniqueKey: fmt.Sprintf("global:%s", key),
			Hits:      0,
			Limit:     int64(conf.GlobalLimit),
			Duration:  int64(conf.GlobalDurationSeconds) * gubernator.Second,
			Algorithm: gubernator.Algorithm_LEAKY_BUCKET,
			Behavior:  gubernator.Behavior_GLOBAL & gubernator.Behavior_DRAIN_OVER_LIMIT,
		})
	}
	return res, true
}
