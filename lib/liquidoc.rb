require "liquidoc"
require 'yaml'
require 'json'
require 'optparse'
require 'liquid'
require 'asciidoctor'
require 'logger'
require 'csv'
require 'crack/xml'

# ===
# Table of Contents
# ===
#
# 1. dependencies stack
# 2. default settings
# 3. general methods
# 4. object classes
# 5. action-specific methods
# 5a. parse methods
# 5b. migrate methods
# 5c. render methods
# 6. text manipulation
# 7. command/option parser
# 8. executive method calls

# ===
# Default settings
# ===

@base_dir_def = Dir.pwd + '/'
@base_dir = @base_dir_def
@configs_dir = @base_dir + '_configs'
@templates_dir = @base_dir + '_templates/'
@data_dir = @base_dir + '_data/'
@output_dir = @base_dir + '_output/'
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
# Executive methods
# ===

# Establish source, template, index, etc details for build jobs from a config file
def config_build config_file
  @logger.debug "Using config file #{config_file}."
  validate_file_input(config_file, "config")
  begin
    config = YAML.load_file(config_file)
  rescue
    unless File.exists?(config_file)
      @logger.error "Config file #{config_file} not found."
    else
      @logger.error "Problem loading config file #{config_file}. Exiting."
    end
    raise "ConfigFileError"
  end
  cfg = BuildConfig.new(config) # convert the config file to a new object called 'cfg'
  iterate_build(cfg)
end

def iterate_build cfg
  stepcount = 0
  for step in cfg.steps # iterate through each node in the 'config' object, which should start with an 'action' parameter
    stepcount = stepcount + 1
    step = BuildConfigStep.new(step) # create an instance of the Action class, validating the top-level step hash (now called 'step') in the process
    type = step.type
    case type # a switch to evaluate the 'action' parameter for each step in the iteration...
    when "parse"
      data = DataSrc.new(step.data)
      builds = step.builds
      for bld in builds
        build = Build.new(bld, type) # create an instance of the Build class; Build.new accepts a 'bld' hash & action 'type'
        liquify(data, build.template, build.output) # perform the liquify operation
      end
    when "migrate"
      @logger.warn "Migrate actions not yet implemented."
    when "render"
      @logger.warn "Render actions not yet implemented."
    when "deploy"
      @logger.warn "Deploy actions not yet implemented."
    else
      @logger.warn "The action `#{type}` is not valid."
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
  if error
    @logger.error "Could not validate input file: #{error}"
    raise "InvalidInput"
  end
end

def validate_config_structure config
  unless config.is_a? Array
    message =  "The configuration file is not properly structured."
    @logger.error message
    raise "ConfigStructError"
  else
    if (defined?(config['action'])).nil?
      message =  "Every listing in the configuration file needs an action type declaration."
      @logger.error message
      raise "ConfigStructError"
    end
  end
# TODO More validation needed
end

# ===
# Core classes
# ===

# For now BuildConfig is mostly to objectify the primary build 'action' steps
class BuildConfig

  def initialize config

    if (defined?(config['compile'][0])) # The config is formatted for vesions < 0.3.0; convert it
      config = deprecated_format(config)
    end

    # validations
    unless config.is_a? Array
      raise "ConfigStructError"
    end

    @@cfg = config
  end

  def steps
    @@cfg
  end

  def deprecated_format config # for backward compatibility with 0.1.0 and 0.2.0
    puts "You are using a deprecated configuration file structure. Update your config files; support for this structure will be dropped in version 1.0.0."
    # There's only ever one item in the 'compile' array, and only one action type ("parse")
    config['compile'].each do |n|
      n.merge!("action" => "parse") # the action type was not previously declared
    end
    return config['compile']
  end

end #class BuildConfig

class BuildConfigStep

  def initialize step
    @@step = step
    @@logger = Logger.new(STDOUT)
    if (defined?(@@step['action'])).nil?
      @logger.error "Every step in the configuration file needs an 'action' type declared."
      raise "ConfigStructError"
    end
  end

  def type
    return @@step['action']
  end

  def data
    return @@step['data']
  end

  def builds
    return @@step['builds']
  end

  def self.validate reqs
    for req in reqs
      if (defined?(@@step[req])).nil?
        @@logger.error "Every #{@@step['action']}-type in the configuration file needs a '#{req}' declaration."
        raise "ConfigStructError"
      end
    end
  end

end #class Action

class Build

  def initialize build, type
    @@build = build
    @@type = type
    @@logger = Logger.new(STDOUT)
    required = []
    case type
    when "parse"
      required = ["template,output"]
    when "render"
      required = ["index,output"]
    when "migrate"
      required = ["source,target"]
    end
    for req in required
      if (defined?(req)).nil?
        raise ActionSettingMissing
      end
    end
  end

  def template
    @@build['template']
  end

  def output
    @@build['output']
  end

  def index
    @@build['index']
  end

  def source
    @@build['source']
  end

  def target
    @@build['target']
  end

end #class Build

class DataSrc
  # initialization means establishing a proper hash for the 'data' param
  def initialize datasrc
    @@datasrc = {}
    if datasrc.is_a? String # create a hash out of the filename
      begin
        @@datasrc['file'] = datasrc
        @@datasrc['ext'] = File.extname(datasrc)
        @@datasrc['type'] = false
        @@datasrc['pattern'] = false
      rescue
        raise "InvalidDataFilename"
      end
    else
      if datasrc.is_a? Hash # data var is a hash, so add 'ext' to it by extracting it from filename
        @@datasrc['file'] = datasrc['file']
        @@datasrc['ext'] = File.extname(datasrc['file'])
        if (defined?(datasrc['pattern']))
          @@datasrc['pattern'] = datasrc['pattern']
        end
        if (defined?(datasrc['type']))
          @@datasrc['type'] = datasrc['type']
        end
      else # datasrc is neither String nor Hash
        raise "InvalidDataSource"
      end
    end
  end

  def file
    @@datasrc['file']
  end

  def ext
    @@datasrc['ext']
  end

  def type
    if @@datasrc['type'] # if we're carrying a 'type' setting for data, pass it along
      datatype = @@datasrc['type']
      if datatype.downcase == "yaml" # This is an expected common error, so let's do the user a solid
        datatype = "yml"
      end
    else # If there's no 'type' defined, extract it from the filename and validate it
      unless @@datasrc['ext'].downcase.match(/\.yml|\.json|\.xml|\.csv/)
        # @logger.error "Data file extension must be one of: .yml, .json, .xml, or .csv or else declared in config file."
        raise "FileExtensionUnknown"
      end
      datatype = @@datasrc['ext']
      datatype = datatype[1..-1] # removes leading dot char
    end
    unless datatype.downcase.match(/yml|json|xml|csv|regex/) # 'type' must be one of these permitted vals
      # @logger.error "Declared data type must be one of: yaml, json, xml, csv, or regex."
      raise "DataTypeUnrecognized"
    end
    datatype
  end

  def pattern
    @@datasrc['pattern']
  end
end

# ===
# Action-specific methods
#
# PARSE-type build methods
# ===

# Pull in a semi-structured data file, converting contents to a Ruby hash
def ingest_data datasrc
# Must be passed a proper data object (there must be a better way to validate arg datatypes)
  unless datasrc.is_a? Object
    raise "InvalidDataObject"
  end
  # This method should really begin here, once the data object is in order
  case datasrc.type
  when "yml"
    begin
      return YAML.load_file(datasrc.file)
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "json"
    begin
      return JSON.parse(File.read(datasrc.file))
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "xml"
    begin
      data = Crack::XML.parse(File.read(datasrc.file))
      return data['root']
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "csv"
    output = []
    i = 0
    begin
      CSV.foreach(datasrc.file, headers: true, skip_blanks: true) do |row|
        output[i] = row.to_hash
        i = i+1
      end
      output = {"data" => output}
      return output
    rescue
      @logger.error "The CSV format is invalid."
    end
  when "regex"
    if datasrc.pattern
      return parse_regex(datasrc.file, datasrc.pattern)
    else
      @logger.error "You must supply a regex pattern with your free-form data file."
      raise "MissingRegexPattern"
    end
  end
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

# Parse given data using given template, generating given output
def liquify datasrc, template_file, output
  @logger.debug "Executing liquify parsing operation."
  if datasrc.is_a? String
    datasrc = DataSrc.new(datasrc)
  end
  validate_file_input(datasrc.file, "data")
  validate_file_input(template_file, "template")
  data = ingest_data(datasrc)
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

# ===
# MIGRATE-type methods
# ===

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
# RENDER-type methods
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
# Text manipulation Classes, Modules, filters, etc
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

# Extending Liquid filters/text manipulation
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

# register custom Liquid filters
Liquid::Template.register_filter(CustomFilters)


# ===
# Command/options parser
# ===

# Define command-line option/argument parameters
# From the root directory of your project:
# $ liquidoc --help
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

command_parser.parse!

# Upfront debug output
@logger.debug "Base dir: #{@base_dir}"
@logger.debug "Config file: #{@config_file}"
@logger.debug "Index file: #{@index_file}"

# ===
# Execute
# ===

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
