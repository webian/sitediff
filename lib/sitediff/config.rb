require 'yaml'
require 'pathname'

class SiteDiff
  class Config

    # keys allowed in configuration files
    CONF_KEYS = Sanitize::TOOLS.values.flatten(1) +
                %w[paths before after before_url after_url includes]

    class InvalidConfig < Exception; end
    class MergeConflict < Exception; end

    # Takes a Hash and normalizes it to the following form by merging globals
    # into before and after. A normalized config Hash looks like this:
    #
    #     paths:
    #     - /about
    #
    #     before:
    #       url: http://before
    #       selector: body
    #       dom_transform:
    #       - type: remove
    #         selector: script
    #
    #     after:
    #       url: http://after
    #       selector: body
    #
    def self.normalize(conf)
      tools = Sanitize::TOOLS

      # merge globals
      %w[before after].each do |pos|
        conf[pos] ||= {}
        tools[:array].each do |key|
          conf[pos][key] ||= []
          conf[pos][key] += conf[key] if conf[key]
        end
        tools[:scalar].each {|key| conf[pos][key] ||= conf[key]}
        conf[pos]['url'] ||= conf[pos + '_url']
      end
      # normalize paths
      conf['paths'] = Config::normalize_paths(conf['paths'])

      conf.select {|k,v| %w[before after paths].include? k}
    end

    # Merges two normalized Hashes. Only "clean" merges are supported, otherwise
    # an InvalidConfig is raised.
    # Two Hashes merge cleanly iff for each site-specific subhash H (e.g.
    # ['before']['dom_transform']) where the Hashes disagree on values, either:
    #   - One of first[H] and second[H] is nil, or
    #   - first[H] and second[H] are arrays
    #
    # For example, (1) does not merge cleanly with (2), but it does with (3):
    #
    # (1) before: {selector: 'body' , sanitization: [pattern: 'form-[0-9a-z]+']}
    # (2) before: {selector: 'div#main'}
    # (3) before: {sanitization: [pattern: 'view-[0-9a-z]+']}
    #
    def self.merge(first, second)
      # paths always cleanly merge
      result = {
        'paths' => (first['paths'] || []) + (second['paths'] || []),
        'before' => {},
        'after' => {}
      }
      %w[before after].each do |pos|
        unless first[pos]
          result[pos] = second[pos] || {}
          next
        end
        result[pos] = first[pos].merge!(second[pos]) do |key, a, b|
          if Sanitize::TOOLS[:array].include? key
            result[pos][key] = a + b
          elsif !(a and b) # at least one is nil: clean merge
            result[pos][key] = a || b
          else
            raise MergeConflict,
              "['#{pos}']['#{key}'] cannot be cleanly merged."
          end
        end
      end
      result
    end

    def initialize(files)
      @config = {'paths' => [], 'before' => {}, 'after' => {} }
      files.each {|f| @config = Config::merge(@config, Config::load_conf(f))}
    end

    def before
      @config['before']
    end
    def after
      @config['after']
    end

    def paths
      @config['paths']
    end
    def paths=(paths)
      @config['paths'] = Config::normalize_paths(paths)
    end

    # Checks if the configuration is usable for diff-ing.
    def validate
      raise InvalidConfig, "Undefined 'before' base URL." unless before['url']
      raise InvalidConfig, "Undefined 'after' base URL." unless after['url']
      raise InvalidConfig, "Undefined 'paths'." unless (paths and !paths.empty?)
    end

    private

    def self.normalize_paths(paths)
      paths ||= []
      return paths.map { |p| (p[0] == '/' ? p : "/#{p}").chomp }
    end

    def self.load_raw_yaml(file)
      SiteDiff::log "Reading config file: #{file}"
      conf = YAML.load_file(file) || {}
      conf.each do |k,v|
        unless CONF_KEYS.include? k
          raise InvalidConfig, "Unknown configuration key (#{file}): '#{k}'"
        end
      end
      conf
    end

    # loads a single YAML configuration file, merges all its 'included' files
    # and returns a normalized Hash.
    def self.load_conf(file, visited=[])
      # don't get fooled by a/../a/
      file = Pathname.new(file).cleanpath.to_s
      if visited.include? file
        raise InvalidConfig, "Circular dependency: #{file}"
      end

      conf = load_raw_yaml(file) # not normalized yet
      visited << file

      # normalize and merge includes
      includes = conf['includes'] || []
      conf = Config::normalize(conf)
      includes.each do |dep|
        # include paths are relative to the including file.
        dep = File.join(File.dirname(file), dep)
        begin
          conf = Config::merge(conf, load_conf(dep, visited))
        rescue MergeConflict => e
          raise InvalidConfig, "Merge conflict (#{file} includes #{dep}) #{e}"
        end
      end
      conf
    end

  end
end
