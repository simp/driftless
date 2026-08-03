module Driftless
  class Reported
    MissingReport = Object.new.freeze

    def initialize(data: {})
      @data = data
    end

    def report(query_name)
      @data.fetch(query_name, MissingReport)
    end

    def missing?(query_name)
      report(query_name).equal?(MissingReport)
    end
  end
end
