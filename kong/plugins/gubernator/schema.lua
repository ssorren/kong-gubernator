local typedefs = require "kong.db.schema.typedefs"


local PLUGIN_NAME = "gubernator"


local schema = {
  name = PLUGIN_NAME,
  fields = {
    -- the 'fields' array is the top-level entry with fields defined by Kong
    { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer (typical for auth plugins)
    { protocols = typedefs.protocols_http},
    { config = {
        -- The 'config' record is the custom part of the plugin schema
        type = "record",
        fields = {
          -- a standard defined field (typedef), with some customizations
          { message = { -- self defined field
              type = "string",
              default = "gubernated",
              required = false, }}, -- adding a constraint for the value
          { global_limit = { -- self defined field
              type = "integer",
              default = -1,
              required = false, }}, -- adding a constraint for the value
          { global_duration_seconds = { -- self defined field
              type = "integer",
              default = 1,
              required = false, }}, -- adding a constraint for the value
          { rules = {
            type = "array",
            elements = {
                type = "record",
                fields = {
                    {name = {
                        type = "string",
                        required = true,
                    }},
                    {header_name = {
                        type = "string",
                        required = true,
                    }},
                    {key_prefix = {
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
                },
            },
          }},
        },
        entity_checks = {},
      },
    },
  },
}

return schema