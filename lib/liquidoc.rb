require "liquidoc"
require 'yaml'
require 'json'
require 'optparse'
require 'liquid'
require 'asciidoctor'
require 'logger'
require 'csv'
require 'crack/xml'

# Default settings
@base_dir_def = Dir.pwd + '/'
@base_dir = @base_dir_def
@configs_dir = @base_dir + '_configs'
@templates_dir = @base_dir + '_templates/'
@data_dir = @base_dir + '_data/'
@output_dir = @base_dir + '_output/'
@config_file_def = @base_dir + '_configs/cfg-sample.yml'
@config_file = @config_file_def
@attributes_file_def = '_data/asciidoctor.yml'
@attributes_file = @attributes_file_def
@pdf_theme_file = 'theme/pdf-theme.yml'
@fonts_dir = 'theme/fonts/'
@output_filename = 'index'
@attributes = {}

@logger = Logger.new(STDOUT)
@logger.level = Logger::INFO
@logger.formatter = proc do |severity, datetime, progname, msg|
  "#{severity}: #{msg}\n"
end

# ===
# General methods
# ===

# Pull in a semi-structured data file, converting contents to a Ruby hash
def get_data data
  # data must be a hash produced by data_hashify()
  if data['type']
    if data['type'].downcase == "yaml"
      data['type'] = "yml"
    end
    unless data['type'].downcase.match(/yml|json|xml|csv|regex/)
      @logger.error "Declared data type must be one of: yaml, json, xml, csv, or regex."
      raise "DataTypeUnrecognized"
    end
  else
    unless data['ext'].match(/\.yml|\.json|\.xml|\.csv/)
      @logger.error "Data file extension must be one of: .yml, .json, .xml, or .csv or else declared in config file."
      raise "FileExtensionUnknown (#{data[ext]})"
    end
    data['type'] = data['ext']
    data['type'].slice!(0) # removes leading dot char
  end
  case data['type']
  when "yml"
    begin
      return YAML.load_file(data['file'])
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "json"
    begin
      return JSON.parse(File.read(data['file']))
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "xml"
    begin
      data = Crack::XML.parse(File.read(data['file']))
      return data['root']
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "csv"
    output = []
    i = 0
    begin
      CSV.foreach(data['file'], headers: true, skip_blanks: true) do |row|
        output[i] = row.to_hash
        i = i+1
      end
      output = {"data" => output}
      return output
    rescue
      @logger.error "The CSV format is invalid."
    end
  when "regex"
    if data['pattern']
      return parse_regex(data['file'], data['pattern'])
    else
      @logger.error "You must supply a regex pattern with your free-form data file."
      raise "MissingRegexPattern"
    end
  end
end

# Establish source, template, index, etc details for build jobs from a config file
# TODO This needs to be turned into a Class?
def config_build config_file
  @logger.debug "Using config file #{config_file}."
  validate_file_input(config_file, "config")
  begin
    config = YAML.load_file(config_file)
  rescue
    unless File.exists?(config_file)
      @logger.error "Config file not found."
    else
      @logger.error "Problem loading config file. Exiting."
    end
    raise "Could not load #{config_file}"
  end
  validate_config_structure(config)
  if config['compile']
    for src in config['compile']
      data = src['data']
      for cfgn in src['builds']
        template = @base_dir + cfgn['template']
        unless cfgn['output'].downcase == "stdout"
          output = @base_dir + cfgn['output']
        else
          output = "stdout"
        end
        liquify(data, template, output)
      end
    end
  end
  if config['publish']
    begin
      for pub in config['publish']
        for bld in pub['builds']
          if bld['publish']
            publish(pub, bld)
          else
            @logger.warn "Publish build for '#{index}' backend '#{backend}' disabled."
          end
        end
      end
    rescue Exception => ex
      @logger.error "Error during publish action. #{ex}"
    end
  end
end

# Verify files exist
def validate_file_input file, type
  @logger.debug "Validating input file for #{type} file #{file}"
  error = false
  unless file.is_a?(String) and !file.nil?
    error = "The #{type} filename (#{file}) is not valid."
  else
    unless File.exists?(file)
      error = "The #{type} file (#{file}) was not found."
    end
  end
  unless error
    @logger.debug "Input file validated for #{type} file #{file}."
  else
    @logger.error "Could not validate input file: #{error}"
    raise "InvalidInput"
  end
end

def validate_config_structure config
  unless config.is_a? Hash
    message =  "The configuration file is not properly structured; it is not a hash"
    @logger.error message
    raise message
  else
    unless config['publish'] or config['compile']
      raise "Config file must have at least one top-level section named 'publish:' or 'compile:'."
    end
  end
# TODO More validation needed
end

def data_hashify data_var
  # TODO make datasource config a class
  if data_var.is_a?(String)
    data = {}
    data['file'] = data_var
    data['ext'] = File.extname(data_var)
  else # add ext to the hash
    data = data_var
    data['ext'] = File.extname(data['file'])
  end
  return data
end

def parse_regex data_file, pattern
  records = []
  pattern_re = /#{pattern}/
  @logger.debug "Using regular expression #{pattern} to parse data file."
  groups = pattern_re.names
  begin
    File.open(data_file, "r") do |file_proc|
      file_proc.each_line do |row|
        matches = row.match(pattern_re)
        if matches
          row_h = {}
          groups.each do |var| # loop over the named groups, adding their key & value to the row_h hash
            row_h.merge!(var => matches[var])
          end
          records << row_h # add the row to the records array
        end
      end
    end
    output = {"data" => records}
  rescue Exception => ex
    @logger.error "Something went wrong trying to parse the free-form file. #{ex.class} thrown. #{ex.message}"
    raise "Freeform parse error"
  end
  return output
end

# ===
# Liquify BUILD methods
# ===

# Parse given data using given template, saving to given filename
def liquify data, template_file, output
  @logger.debug "Executing liquify parsing operation."
  data = data_hashify(data)
  validate_file_input(data['file'], "data")
  validate_file_input(template_file, "template")
  data = get_data(data) # gathers the data
  begin
    template = File.read(template_file) # reads the template file
    template = Liquid::Template.parse(template) # compiles template
    rendered = template.render(data) # renders the output
  rescue Exception => ex
    message = "Problem rendering Liquid template. #{template_file}\n" \
      "#{ex.class} thrown. #{ex.message}"
    @logger.error message
    raise message
  end
  unless output.downcase == "stdout"
    output_file = output
    begin
      Dir.mkdir(@output_dir) unless File.exists?(@output_dir)
      File.open(output_file, 'w') { |file| file.write(rendered) } # saves file
    rescue Exception => ex
      @logger.error "Failed to save output.\n#{ex.class} #{ex.message}"
    end
    if File.exists?(output_file)
      @logger.info "File built: #{File.basename(output_file)}"
    else
      @logger.error "Hrmp! File not built."
    end
  else # if stdout
    puts "========\nOUTPUT: Rendered with template #{template_file}:\n\n#{rendered}\n"
  end
end

# Copy images and other assets into output dir for HTML operations
def copy_assets src, dest
  if @recursive
    dest = "#{dest}/#{src}"
    recursively = "Recursively c"
  else
    recursively = "C"
  end
  @logger.debug "#{recursively}opying image assets to #{dest}"
  begin
    FileUtils.mkdir_p(dest) unless File.exists?(dest)
    FileUtils.cp_r(src, dest)
  rescue Exception => ex
    @logger.warn "Problem while copying assets. #{ex.message}"
    return
  end
  @logger.debug "\s\s#{recursively}opied: #{src} --> #{dest}/#{src}"
end

# ===
# PUBLISH methods
# ===

# Gather attributes from a fixed attributes file
# Use _data/attributes.yml or designate as -a path/to/filename.yml
def get_attributes attributes_file
  if attributes_file == nil
    attributes_file = @attributes_file_def
  end
  validate_file_input(attributes_file, "attributes")
  begin
    attributes = YAML.load_file(attributes_file)
    return attributes
  rescue
    @logger.warn "Attributes file invalid."
  end
end

# Set attributes for direct Asciidoctor operations
def set_attributes attributes
  unless attributes.is_a?(Enumerable)
    attributes = { }
  end
  attributes["basedir"] = @base_path
  attributes.merge!get_attributes(@attributes_file)
  attributes = '-a ' + attributes.map{|k,v| "#{k}='#{v}'"}.join(' -a ')
  return attributes
end

# To be replaced with a gem call
def publish pub, bld
  @logger.warn "Publish actions not yet implemented."
end

# ===
# Misc Classes, Modules, filters, etc
# ===

class String
# Adapted from Nikhil Gupta
# http://nikhgupta.com/code/wrapping-long-lines-in-ruby-for-display-in-source-files/
  def wrap options = {}
    width = options.fetch(:width, 76)
    commentchar = options.fetch(:commentchar, '')
    self.strip.split("\n").collect do |line|
      line.length > width ? line.gsub(/(.{1,#{width}})(\s+|$)/, "\\1\n#{commentchar}") : line
    end.map(&:strip).join("\n#{commentchar}")
  end

  def indent options = {}
    spaces = " " * options.fetch(:spaces, 4)
    self.gsub(/^/, spaces).gsub(/^\s*$/, '')
  end

  def indent_with_wrap options = {}
    spaces = options.fetch(:spaces, 4)
    width  = options.fetch(:width, 80)
    width  = width > spaces ? width - spaces : 1
    self.wrap(width: width).indent(spaces: spaces)
  end

end

# Liquid modules for text manipulation
module CustomFilters
  def plainwrap input
    input.wrap
  end
  def commentwrap input
    input.wrap commentchar: "# "
  end
  def unwrap input # Not fully functional; inserts explicit '\n'
    if input
      token = "[g59hj1k]"
      input.gsub(/\n\n/, token).gsub(/\n/, ' ').gsub(token, "\n\n")
    end
  end

  # From Slate Studio's fork of Locomotive CMS engine
  # https://github.com/slate-studio/engine/blob/master/lib/locomotive/core_ext.rb
  def slugify(options = {})
    options = { :sep => '_', :without_extension => false, :downcase => false, :underscore => false }.merge(options)
    # replace accented chars with ther ascii equivalents
    s = ActiveSupport::Inflector.transliterate(self).to_s
    # No more than one slash in a row
    s.gsub!(/(\/[\/]+)/, '/')
    # Remove leading or trailing space
    s.strip!
    # Remove leading or trailing slash
    s.gsub!(/(^[\/]+)|([\/]+$)/, '')
    # Remove extensions
    s.gsub!(/(\.[a-zA-Z]{2,})/, '') if options[:without_extension]
    # Downcase
    s.downcase! if options[:downcase]
    # Turn unwanted chars into the seperator
    s.gsub!(/[^a-zA-Z0-9\-_\+\/]+/i, options[:sep])
    # Underscore
    s.gsub!(/[\-]/i, '_') if options[:underscore]
    s
  end
  def slugify!(options = {})
    replace(self.slugify(options))
  end
  def parameterize!(sep = '_')
    replace(self.parameterize(sep))
  end

end

Liquid::Template.register_filter(CustomFilters)

# Define command-line option/argument parameters
# From the root directory of your project:
# $ ./parse.rb --help
command_parser = OptionParser.new do|opts|
  opts.banner = "Usage: liquidoc [options]"

  opts.on("-a PATH", "--attributes-file=PATH", "For passing in a standard YAML AsciiDoc attributes file. Default: #{@attributes_file_def}") do |n|
    @assets_path = n
  end

  opts.on("--attr=STRING", "For passing an AsciiDoc attribute parameter to Asciidoctor. Ex: --attr basedir=some/path --attr imagesdir=some/path/images") do |n|
    @passed_attrs = @passed_attrs.merge!n
  end

  # Global Options
  opts.on("-b PATH", "--base=PATH", "The base directory, relative to this script. Defaults to `.`, or pwd." ) do |n|
    @data_file = @base_dir + n
  end

  opts.on("-c", "--config=PATH", "Configuration file, enables preset source, template, and output.") do |n|
    @config_file = @base_dir + n
  end

  opts.on("-d PATH", "--data=PATH", "Semi-structured data source (input) path. Ex. path/to/data.yml. Required unless --config is called." ) do |n|
    @data_file = @base_dir + n
  end

  opts.on("-f PATH", "--from=PATH", "Directory to copy assets from." ) do |n|
    @attributes_file = n
  end

  opts.on("-i PATH", "--index=PATH", "An AsciiDoc index file for mapping an Asciidoctor build." ) do |n|
    @index_file = n
  end

  opts.on("-o PATH", "--output=PATH", "Output file path for generated content. Ex. path/to/file.adoc. Required unless --config is called.") do |n|
    @output_file = @base_dir + n
  end

  opts.on("-t PATH", "--template=PATH", "Path to liquid template. Required unless --configuration is called." ) do |n|
    @template_file = @base_dir + n
  end

  opts.on("--verbose", "Run verbose") do |n|
    @logger.level = Logger::DEBUG
  end

  opts.on("--stdout", "Puts the output in STDOUT instead of writing to a file.") do
    @output_type = "stdout"
  end

  opts.on("-h", "--help", "Returns help.") do
    puts opts
    exit
  end

end

# Parse options.
command_parser.parse!

# Upfront debug output
@logger.debug "Base dir: #{@base_dir}"
@logger.debug "Config file: #{@config_file}"
@logger.debug "Index file: #{@index_file}"

# Parse data into docs!
# liquify() takes the names of a Liquid template, a data file, and an output doc.
# Input and output file extensions are non-determinant; your template
# file establishes the structure.

unless @config_file
  if @data_file
    liquify(@data_file, @template_file, @output_file)
  end
  if @index_file
    @logger.warn "Publishing via command line arguments not yet implemented. Use a config file."
  end
else
  @logger.debug "Executing... config_build"
  config_build(@config_file)
end
