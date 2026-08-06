require 'puppet'

require 'driftless/models/puppet_class'
require 'driftless/models/class_parameter'
require 'driftless/role_profile'

module Driftless
  class ClassExtractor
    def self.extract(program:, file:)
      new(program: program, file: file).extract
    end

    def initialize(program:, file:)
      @program = program
      @file    = file
    end

    def extract
      classes = []
      @program._pcore_all_contents([]) do |node|
        next unless node.is_a?(Puppet::Pops::Model::HostClassDefinition) ||
                    node.is_a?(Puppet::Pops::Model::ResourceTypeDefinition)
        classes << build_class(node)
      end
      classes
    end

    private

    def build_class(node)
      fqname = node.name
      PuppetClass.new(
        fqname:  fqname,
        file:    @file,
        params:  build_params(node),
        role:    RoleProfile.role?(fqname),
        profile: RoleProfile.profile?(fqname),
      )
    end

    def build_params(node)
      Array(node.parameters).map do |param|
        ClassParameter.new(
          name:         param.name,
          default_expr: param.value,
          type_expr:    param.type_expr,
        )
      end
    end
  end
end
