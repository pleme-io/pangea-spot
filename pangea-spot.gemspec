# frozen_string_literal: true

lib = File.expand_path(%(lib), __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require_relative %(lib/pangea-spot/version)

Gem::Specification.new do |spec|
  spec.name                  = %(pangea-spot)
  spec.version               = PangeaSpot::VERSION
  spec.authors               = [%(Luis Zayas)]
  spec.email                 = [%(drzthslnt@gmail.com)]
  spec.description           = %(Spot-instance architecture pack for Pangea. Typed instance-type catalog (22 profiles across 9 workload categories), allocation strategies, interruption handlers, topology architectures, cross-cloud abstractions.)
  spec.summary               = %(Spot-instance architecture pack for Pangea)
  spec.homepage              = %(https://github.com/pleme-io/pangea-spot)
  spec.license               = %(Apache-2.0)
  spec.require_paths         = [%(lib)]
  spec.required_ruby_version = %(>=3.3.0)

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  spec.add_dependency "pangea-core", "~> 0.2"
  spec.add_dependency "pangea-aws", "~> 0.1"
  spec.add_dependency "terraform-synthesizer", "~> 0.0.28"
  spec.add_dependency "dry-types", "~> 1.7"
  spec.add_dependency "dry-struct", "~> 1.6"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"

  spec.metadata['rubygems_mfa_required'] = 'true'
end
