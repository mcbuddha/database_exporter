module DatabaseExporter
  Transformers = {
    'sanitize_email' => ->(i, rec) { "email#{i.to_s.rjust(5, ?0)}@#{rec.split(?@)[1]}"},
    'wipe' => proc { nil },
    'zero' => proc { 0 },
    'empty_string' => proc { '' },
    'sanitize_name' => proc { 'John Doe' },
    'sanitize_phone_number' => ->(i, rec) { rec.nil? ? rec : "#{rec[0,3]}#{i.to_s.rjust rec.length-3, ?0}" }
  }
end
