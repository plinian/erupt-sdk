# frozen_string_literal: true

require "json"

module Erupt
  # Checks annotation JSON against erupt-annotations.schema.json (the same schema types.rb is generated from),
  # so a misspelt attribute or an unknown enum value fails when the model is declared instead of silently
  # doing nothing in the browser.
  module Schema
    DEFS = JSON.parse(File.read(File.join(__dir__, "schema.json")))["$defs"]

    PRIMITIVES = {
      "string" => ->(v) { v.is_a?(String) },
      "integer" => ->(v) { v.is_a?(Integer) },
      "number" => ->(v) { v.is_a?(Numeric) },
      "boolean" => ->(v) { v == true || v == false }
    }.freeze

    module_function

    def enum_values(name) = DEFS.fetch(name).fetch("enum")

    # The declared defaults of an annotation, as Java fills an attribute left out.
    def defaults(name) = DEFS.fetch(name)["properties"].each_with_object({}) { |(k, v), h| h[k] = v["default"] if v.key?("default") }

    # Raise ArgumentError unless +value+ fits definition +name+. +partial+ (an override) lets every attribute
    # be omitted; otherwise the attributes the Java side always emits must be present.
    def check(name, value, path = name, partial: true)
      walk({ "$ref" => "#/$defs/#{name}" }, value, path, partial)
    end

    def walk(schema, value, path, partial)
      return walk_ref(schema["$ref"].split("/").last, value, path, partial) if schema["$ref"]

      kind = schema["type"]
      case kind
      when "array"
        raise ArgumentError, "#{path}: expected an array" unless value.is_a?(Array)

        value.each_with_index { |item, i| walk(schema["items"], item, "#{path}[#{i}]", partial) }
      when "object"
        raise ArgumentError, "#{path}: expected an object" unless value.is_a?(Hash)

        value.each { |k, item| walk(schema["additionalProperties"], item, "#{path}.#{k}", partial) } if schema["additionalProperties"]
      else
        raise ArgumentError, "#{path}: expected #{kind}, got #{JSON.generate(value)}" unless PRIMITIVES.fetch(kind).call(value)
      end
    end

    def walk_ref(name, value, path, partial)
      d = DEFS.fetch(name)
      if d["enum"]
        return if d["enum"].include?(value)

        raise ArgumentError, "#{path}: '#{value}' is not a #{name}, expected one of #{d["enum"].join(", ")}"
      end
      raise ArgumentError, "#{path}: expected an object (#{name})" unless value.is_a?(Hash)

      value.each do |key, item|
        raise ArgumentError, "#{path}: #{name} has no attribute '#{key}'" unless d["properties"].key?(key)

        walk(d["properties"][key], item, "#{path}.#{key}", partial)
      end
      missing = partial ? [] : (d["required"] || []) - value.keys
      raise ArgumentError, "#{path}: missing #{missing.join(", ")}" unless missing.empty?
    end
  end
end
