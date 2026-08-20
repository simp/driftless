module Driftless
  class Reported
    MissingReport = Object.new.freeze

    # @param duplicate_certnames [Hash{String => Array<String>}] certnames more
    #   than one collector reported, mapped to the collectors that claimed them.
    def initialize(data: {}, duplicate_certnames: {})
      @data                = data
      @duplicate_certnames = duplicate_certnames
    end

    attr_reader :duplicate_certnames

    def report(query_name)
      @data.fetch(query_name, MissingReport)
    end

    def missing?(query_name)
      report(query_name).equal?(MissingReport)
    end
  end
end
