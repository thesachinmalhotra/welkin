package main

// Welkin-canonical CloudEvent schema.
//
// This is stricter than the base CloudEvents 1.0 spec, which requires only
// id, source, specversion, and type. Welkin adds time, subject, and data as
// mandatory because:
//   - archive parquet columns require time and subject
//   - metering (OpenMeter) requires subject for aggregation
//   - economic processing requires data for value extraction
//
// datacontenttype remains optional — it is informational and not consumed
// downstream.
cloudEventSchema: {
  $schema:     "https://json-schema.org/draft/2020-12/schema"
  title:       "Welkin CloudEvent"
  description: "Welkin-canonical CloudEvent — stricter than base CE 1.0"
  type:        "object"
  required: [
    "specversion",
    "id",
    "source",
    "type",
    "time",
    "subject",
    "data",
  ]
  properties: {
    specversion: {
      type:        "string"
      description: "CloudEvents spec version"
      const:       "1.0"
    }
    id: {
      type:        "string"
      description: "Event identifier, unique within source"
      minLength:   1
    }
    source: {
      type:        "string"
      description: "Event source identifier"
      minLength:   1
    }
    type: {
      type:        "string"
      description: "Event type"
      minLength:   1
    }
    time: {
      type:        "string"
      format:      "date-time"
      description: "Event timestamp (RFC 3339)"
    }
    subject: {
      type:        "string"
      description: "Subject of the event (used for metering aggregation)"
      minLength:   1
    }
    datacontenttype: {
      type:        "string"
      description: "Content type of data (optional, informational)"
    }
    data: {
      type:        "object"
      description: "Event payload"
    }
  }
  additionalProperties: true
}
