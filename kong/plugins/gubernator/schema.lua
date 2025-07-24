local typedefs = require "kong.db.schema.typedefs"

local METHODS = {
  "GET",
  "HEAD",
  "PUT",
  "PATCH",
  "POST",
  "DELETE",
  "OPTIONS",
  "TRACE",
  "CONNECT",
}

return {
  name = "gubernator",
  fields = {
    -- the 'fields' array is the top-level entry with fields defined by Kong
    { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer
    { protocols = typedefs.protocols_http},
    { config = {
        type = "record",
        fields = {
          { gubernator_protocol = {
              type = "string",
              default = "http",
              required = false, }},
          { gubernator_host = {
              type = "string",
              default = "127.0.0.1",
              required = false, }},
          { gubernator_port = {
              type = "string",
              default = "1050",
              required = false, }},
          { global_limit = {
              type = "integer",
              default = -1, -- -1 == unlimited
              required = false, }},
          { global_duration_seconds = {
              type = "integer",
              default = 1, -- default of 1 second
              required = false, }},
          { rules = {
            type = "array",
            elements = {
                type = "record",
                fields = {
                    {name = {
                        type = "string",
                        required = true,
                    }},
                    {methods = {
                        type = "array",
                        default = METHODS,
                        elements = {
                            type = "string",
                            one_of = METHODS,
                        },
                    }},
                    {input_source = {
                        type = "string",
                        required = true,
                        default = "HEADER",
                        one_of = {
                            "HEADER",
                            "JWT_SUBJECT",
                            "JWT_CLAIM",
                            -- not yet implemented
                            -- "CONSUMER", 
                            -- "CONSUMER_GROUP",
                        },

                    }},
                    {input_key_name = {
                        type = "string",
                        required = false,
                    }},
                    {rate_limit_key_prefix = {
                        type = "string",
                        required = true,
                    }},
                    {limit = {
                        type = "integer",
                        required = true,
                        default = 1,
                    }},
                    {duration_seconds = {
                        type = "integer",
                        required = true,
                        default = 1,
                    }},
                    {limit_type = {
                        type = "string",
                        required = true,
                        default = "REQUESTS",
                        one_of = {
                            "REQUESTS",
                            "TOKENS",
                        }
                    }},
                    {overrides = {
                        type = "array",
                        elements = {
                            type = "record",
                            fields = {
                                {desc = {
                                    type = "string",
                                    required = false,
                                }},
                                {input_source = {
                                    type = "string",
                                    required = true,
                                    default = "INHERIT",
                                    one_of = {
                                        "INHERIT",
                                        "HEADER",
                                        "JWT_SUBJECT",
                                        "JWT_CLAIM",
                                        -- not yet implemented
                                        -- "CONSUMER", 
                                        -- "CONSUMER_GROUP",
                                    },

                                }},
                                {input_key_name = {
                                    type = "string",
                                    required = false,
                                }},
                                {match_type = {
                                    type = "string",
                                    required = true,
                                    default = "EXACT_MATCH",
                                    one_of = {
                                        "PREFIX",
                                        "EXACT_MATCH",
                                    },
                                }},
                                {match_expr = {
                                    type = "string",
                                    required = true,
                                }},
                                {limit = {
                                    type = "integer",
                                    required = true,
                                    default = -1, 
                                }},
                                {duration_seconds = {
                                    type = "integer",
                                    required = true,
                                    default = 1,
                                }},
                            },
                        },
                    }},
                },
            },
          }},
        },
        entity_checks = {},
      },
    },
  },
}