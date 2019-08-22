require 'liquidoc'
require 'optparse'
require 'yaml'
require 'json'
require 'liquid'
require 'asciidoctor'
require 'asciidoctor-pdf'
require 'logger'
require 'csv'
require 'crack/xml'
require 'fileutils'
require 'open3'
require 'highline'
require 'liquid/tags/jekyll'
require 'liquid/filters/jekyll'
require 'word_wrap'
require 'word_wrap/core_ext'
require 'sterile'

# ===
# Table of Contents
# ===
#
# 1. dependencies stack
# 2. default settings
# 3. general procs def
# 4. object classes def
# 5. action-specific procs def
# 5a. parse procs def
# 5b. migrate procs def
# 5c. render procs def
# 5d. execute procs def
# 6. text manipulation filters
# 7. command/option parser def
# 8. executive proc calls

# ===
# Default settings
# ===

@base_dir_def = Dir.pwd + '/'
@base_dir = @base_dir_def
@build_dir_def = @base_dir + '_build'
@build_dir = @build_dir_def
@configs_dir = @base_dir + '_configs'
@templates_dir = @base_dir + '_templates/'
@includes_dirs_def = ['_templates']
@includes_dirs = @includes_dirs_def
@data_dir = @base_dir + '_data/'
@data_file = nil
@attributes_file_def = '_data/asciidoctor.yml'
@attributes_file = @attributes_file_def
@pdf_theme_file = 'theme/pdf-theme.yml'
@fonts_dir = 'theme/fonts/'
@output_filename = 'index'
@attributes = {}
@passed_attrs = {}
@passed_vars = {}
@passed_configvars = {}
@parseconfig = false
@verbose = false
@quiet = false
@explicit = false
@search_index = false
@search_index_dry = ''
@safemode = true

# Instantiate the main Logger object, which is always running
@logger = Logger.new(STDOUT)
@logger.formatter = proc do |severity, datetime, progname, msg|
  "#{severity}: #{msg}\n"
end
@logger.level = Logger::INFO # suppresses DEBUG-level messages


FileUtils::mkdir_p("#{@build_dir}") unless File.exists?("#{@build_dir}")
FileUtils::mkdir_p("#{@build_dir}/pre") unless File.exists?("#{@build_dir}/pre")


# ===
# Executive procs
# ===

# Establish source, template, index, etc details for build jobs from a config file
def config_build config_file, config_vars={}, parse=false

  @logger.debug "Using config file #{config_file}."
  config = File.read(config_file)
  if (config_vars.length > 0 or parse or config.contains_liquid?)
    @logger.debug "Config_vars: #{config_vars.length}"
  # If config variables are passed on the CLI, we want to parse the config file
  # and use the parsed version for the rest fo this routine
    config_out = "#{@build_dir}/pre/#{File.basename(config_file)}"
    vars = DataObj.new()
    vars.add_data!(config_vars, "vars")
    config_dir = File.dirname(config_file)
    includes_dirs = config_dir.force_array
    vars.add_data!(includes_dirs, :includes_dirs)
    liquify(vars, config_file, config_out)
    config_file = config_out
    @logger.debug "Config parsed! Using #{config_out} for build."
  end
  validate_file_input(config_file, "config")
  begin
    config = YAML.load_file(config_file)
  rescue Exception => ex
    unless File.exists?(config_file)
      @logger.error "Config file #{config_file} not found."
    else
      @logger.error "Problem loading config file #{config_file}. #{ex} Exiting."
    end
    raise "ConfigFileError"
  end
  # TESTS
  # puts config[0].argify
  cfg = BuildConfig.new(config) # convert the config file to a new object called 'cfg'
  if @safemode
    commands = ""
    cfg.steps.each do |step|
      if step['action'] == "execute"
        commands = commands + "> " + step['command'] + "\n"
      end
    end
    unless commands.to_s.strip.empty?
      puts "\nWARNING: This routine will execute the following shell commands:\n\n#{commands}"
      ui = HighLine.new
      answer = ui.ask("\nDo you approve? (YES/no): ")
      raise "CommandExecutionsNotAuthorized" unless answer.strip == "YES"
    end
  end
  iterate_build(cfg)
end

def iterate_build cfg
  stepcount = 0
  for step in cfg.steps # iterate through each node in the 'config' object, which should start with an 'action' parameter
    stepcount = stepcount + 1
    step = BuildConfigStep.new(step) # create an instance of the Action class, validating the top-level step hash (now called 'step') in the process
    @explainer.info step.message
    type = step.type
    case type # a switch to evaluate the 'action' parameter for each step in the iteration...
    when "parse"
      builds = step.builds
      data_obj = DataObj.new()
      if step.data
        data_files = DataFiles.new(step.data)
        data_files.sources.each do |src|
          begin
            data = ingest_data(src) # Extract data from file
          rescue Exception => ex
            @logger.error "#{ex.class}: #{ex.message}"
            raise "DataFileReadFail (#{src.file})"
          end
          begin # Create build.data
            if data_files.sources.size == 1
              data_obj.add_data!(data) if data.is_a? Hash
              # Insert arrays into the data. scope, and for backward compatibility, hashes as well
              data_obj.add_data!(data, "data")
            else
              data_obj.add_data!(src.name, data) # Insert object under self-named scope
            end
          rescue Exception => ex
            @logger.error "#{ex.class}: #{ex.message}"
            raise "DataIngestFail (#{src.file})"
          end
        end
      end
      builds.each do |bld|
        build = Build.new(bld, type, data_obj) # create an instance of the Build class; Build.new accepts a 'bld' hash & action 'type'
        if build.template
          # Prep & perform a Liquid-parsed build
          @explainer.info build.message
          build.add_data!(build.variables, "vars") if build.variables
          includes_dirs = @includes_dirs
          includes_dirs = build.includes_dirs if build.includes_dirs
          build.add_data!({:includes_dirs=>includes_dirs})
          liquify(build.data, build.template, build.output) # perform the liquify operation
        else # Prep & perform a direct conversion
          # Delete nested data and vars objects
          build.data.remove_scope("data")
          build.data.remove_scope("vars")
          # Add vars from CLI or config args
          build.data.add_data!(build.variables) unless build.variables.empty?
          build.data.add_data!(@passed_vars) unless @passed_vars.empty?
          regurgidata(build.data, build.output)
        end
      end
    when "migrate"
      inclusive = true
      missing = "exit"
      if step.options
        inclusive = step.options['inclusive'] if step.options.has_key?("inclusive")
        missing = step.options['missing'] if step.options.has_key?("missing")
      end
      copy_assets(step.source, step.target, inclusive, missing)
    when "render"
      validate_file_input(step.source, "source") if step.source
      builds = step.builds
      for bld in builds
        doc = AsciiDocument.new(step.source)
        attrs = ingest_attributes(step.data) if step.data # Set attributes from YAML files
        doc.add_attrs!(attrs) # Set attributes from the action-level data file
        build = Build.new(bld, type) # create an instance of the Build class; Build.new accepts a 'bld' hash & action 'type' string
        build.set("backend", derive_backend(doc.type, build.output) ) unless build.backend
        @explainer.info build.message
        render_doc(doc, build) # perform the render operation
      end
    when "deploy"
      @logger.warn "Deploy actions are limited and experimental."
      jekyll_serve(build)
    when "execute"
      @logger.info "Executing shell command: #{step.command}"
      execute_command(step)
    else
      @logger.warn "The action `#{type}` is not valid."
    end
  end
end

# ===
# Helper procs
# ===

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

def explainer_init out=nil
  unless @explainer
    if out == "STDOUT"
      @explainer = Logger.new(STDOUT)
    else
      out = "#{@build_dir}/pre/config-explainer.adoc" if out.nil?
      File.open(out, 'w') unless File.exists?(out)
      file = File.open(out, File::WRONLY)
      begin
        @explainer = Logger.new(file)
      rescue Exception => ex
        @logger.error ex
        raise "ExplainerCreateError"
      end
    end
    @explainer.formatter = proc do |severity, datetime, progname, msg|
      "#{msg}\n"
    end
  end
end

def generate_file content, target
  base_path = File.dirname(target)
  begin
    FileUtils::mkdir_p(base_path) unless File.exists?(base_path)
    File.open(target, 'w') { |file| file.write(content) } # saves file
  rescue Exception => ex
    @logger.error "Failed to save output.\n#{ex.class} #{ex.message}"
    raise "FileNotBuilt"
  end
  if File.exists?(target)
    @logger.info "File built: #{target}"
  else
    @logger.error "Hrmp! File not built."
    raise "FileNotBuilt"
  end
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
    validate(config)
    @cfg = config
  end

  def steps
    @cfg
  end

  def deprecated_format config # for backward compatibility with 0.1.0 and 0.2.0
    puts "You are using a deprecated configuration file structure. Update your config files; support for this structure will be dropped in version 1.0.0."
    # There's only ever one item in the 'compile' array, and only one action type ("parse")
    config['compile'].each do |n|
      n.merge!("action" => "parse") # the action type was not previously declared
    end
    return config['compile']
  end

  def validate config
    unless config.is_a? Array
      raise "ConfigStructError"
    end
  # TODO More validation needed
  end

end #class BuildConfig

class BuildConfigStep

  def initialize step
    @step = step
    if (defined?(@step['action'])).nil?
      raise "StepStructError"
    end
    @step['options'] = nil unless defined?(step['options'])
    validate()
  end

  def type
    return @step['action']
  end

  def data
    return @step['data']
  end

  def source
    return @step['source']
  end

  def target
    return @step['target']
  end

  def options
    return @step['options']
  end

  def command
    return @step['command']
  end

  def stage
    return @step['stage']
  end

  def builds
    return @step['builds']
  end

  def message
    # dynamically build a human-friendly log message, possibly appending a reason
    unless @step['message']
      reason = ", #{@step['reason']}" if @step['reason']
      noninclusively = ", without carrying the parent directory" if self.options.is_a?(Hash) && self.options['inclusive'] == false && File.directory?(self.source)
      stage = "" ; stage = "[#{self.stage}] " if self.stage
      case self.type
      when "migrate"
        text = ". #{stage}Copies `#{self.source}` to `#{self.target}`#{noninclusively}#{reason}."
      when "parse"
        if self.data.is_a? Array
          if self.data.count > 1
            text = ". Draws data from the following files:"
            self.data.each do |file|
              text.concat("\n  * `#{file}`.")
            end
            text.concat("\n")
          else
            text = ". #{stage}Draws data from `#{self.data[0]}`"
          end
        else
          if self.data
            text = ". #{stage}Draws data from `#{self.data['file']}`"
          else
            text = ". #{stage}Uses data passed via CLI --var options."
          end
        end
        text.concat("#{reason},") if reason
        text.concat(" and parses it as follows:")
        return text
      when "render"
        if self.source
          text = ". #{stage}Using the index file `#{self.source}` as a map#{reason}, and ingesting AsciiDoc attributes from "
          if self.data.is_a? Array
            text.concat("the following data files:")
            self.data.each do |file|
              text.concat("\n  * `#{file}`.")
            end
          else
            text.concat("`#{self.data}`")
          end
          return text
        end
      end
    else
      return @step['message']
    end
  end

  def validate
    case self.type
    when "parse"
      reqs = ["data,builds"]
    when "migrate"
      reqs = ["source,target"]
    when "render"
      reqs = ["builds"]
    when "execute"
      reqs = ["command"]
    end
    for req in reqs
      if (defined?(@step[req])).nil?
        @logger.error "Every #{@step['action']}-type in the configuration file needs a '#{req}' declaration."
        raise "ConfigStepError"
      end
    end
  end

end #class Action

class Build

  def initialize build, type, data=DataObj.new
    build['attributes'] = Hash.new unless build['attributes']
    build['props'] = build['properties'] if build['properties']
    @build = build
    @type = type
    @data = data
    @build['variables'] = {} unless @build['variables']
  end

  def template
    @build['template']
  end

  def includes_dirs
    @build['includes_dirs']
  end

  def output
    @build['output']
  end

  def style
    @build['style']
  end

  def doctype
    @build['doctype']
  end

  def backend
    @build['backend']
  end

  def props
    @build['props']
  end

  def variables
    # Variables added in the config build:variables: param
    # Not for manipulation
    @build['variables']
  end

  def data
    @data unless @data.nil?
  end

  def add_data! obj, scope=""
    @data.add_data!(obj, scope)
  end

  # def vars
  #   self.data['vars']
  # end

  def message
    # dynamically build a message, possibly appending a reason
    unless @build['message']
      reason = ", #{@build['reason']}" if @build['reason']
      case @type
      when "parse"
        text = ".. Builds `#{self.output}` pressed with the template `#{self.template}`#{reason}."
      when "render"
        case self.backend
        when "pdf"
          text = ".. Uses Asciidoctor/Prawn to generate a PDF file `#{self.output}`"
          text.concat("#{reason}") if reason
          text.concat(".")
        when "html5"
          text = ".. Compiles a standard Asciidoctor HTML5 file, `#{self.output}`"
          text.concat("#{reason}") if reason
          text.concat(".")
        when "jekyll"
          text = ".. Uses Jekyll config files:\n+\n--"
          files = self.props['files']
          if files.is_a? String
            if files.include? ","
              files = files.split(",")
            else
              files = files.split
            end
          else
            unless files.is_a? Array
              @logger.error "The Jekyll configuration file must be a single filename, a comma-separated list of filenames, or an array of filenames."
            end
          end
          files.each do |file|
            text.concat("\n  * `#{file}`")
          end
          text.concat("\n\nto generate a static site")
          if self.props && self.props['arguments']
            text.concat(" at `#{self.props['arguments']['destination']}`")
          end
          text.concat("#{reason}") if reason
          text.concat(".\n--\n")
        end
        return text
      end
    else
      @build['message']
    end
  end

  def prop_files_array
    if props
      if props['files']
        begin
          props['files'].force_array if props['files']
        rescue Exception => ex
          raise "PropertiesFilesArrayError: #{ex}"
        end
      end
    else
      Array.new
    end
  end

  def search
    props['search']
  end

  def add_search_prop! prop
    begin
      self.search.merge!prop
    rescue
      raise "PropertyInsertionError"
    end
  end

  # NOTE this section repeats in Class.AsciiDocument
  def attributes
    @build['attributes']
  end

  def add_attrs! attrs
    begin
      attrs.to_h unless attrs.is_a? Hash
      self.attributes.merge!attrs
    rescue
      raise "InvalidAttributesFormat"
    end
  end

  def set key, val
    @build[key] = val
  end

  def self.set key, val
    @build[key] = val
  end

  def add_config_file config_file
    @build['props'] = Hash.new unless @build['props']
    @build['props']['files'] = Array.new unless @build['props']['files']
    begin
      files_array = @build['props']['files'].force_array
      @build['props']['files'] = files_array.push(config_file)
    rescue
      raise "PropertiesFilesArrayError"
    end
  end

  def validate
    reqs = []
    case self.type
    when "parse"
      reqs = ["template,output"]
    when "render"
      reqs = ["output"]
    end
    for req in reqs
      if (defined?(req)).nil?
        raise "ActionSettingMissing"
      end
    end
  end

end # class Build

class DataSrc
  # initialization means establishing a proper hash for the 'data' param
  def initialize sources
    @datasrc = {}
    @datasrc['file'] = sources
    @datasrc['ext'] = ''
    @datasrc['pattern'] = nil
    if sources.is_a? Hash # data var is a hash, so add 'ext' to it by extracting it from filename
      @datasrc['file'] = sources['file']
      @datasrc['ext'] = File.extname(sources['file'])
      if (defined?(sources['pattern']))
        @datasrc['pattern'] = sources['pattern']
      end
      if (defined?(sources['type']))
        @datasrc['type'] = sources['type']
      end
    elsif sources.is_a? String
      @datasrc['ext'] = File.extname(sources)
    elsif sources.is_a? Array
      sources.each do |src|
        @datasrc['name'] = File.basename(@datasrc['file'])
      end
    else
      raise "InvalidDataSource"
    end
  end

  def file
    @datasrc['file']
  end

  def ext
    @datasrc['ext']
  end

  def name
    File.basename(self.file,File.extname(self.file))
  end

  def type
    if @datasrc['type'] # if we're carrying a 'type' setting for data, pass it along
      datatype = @datasrc['type']
      if datatype.downcase == "yaml" # This is an expected common error, so let's do the user a solid
        datatype = "yml"
      end
    else # If there's no 'type' defined, extract it from the filename and validate it
      unless @datasrc['ext'].downcase.match(/\.yml|\.json|\.xml|\.csv/)
        # @logger.error "Data file extension must be one of: .yml, .json, .xml, or .csv or else declared in config file."
        raise "FileExtensionUnknown"
      end
      datatype = self.ext
      datatype = datatype[1..-1] # removes leading dot char
    end
    unless datatype.downcase.match(/yml|json|xml|csv|regex/) # 'type' must be one of these permitted vals
      # @logger.error "Declared data type must be one of: yaml, json, xml, csv, or regex."
      raise "DataTypeUnrecognized"
    end
    datatype
  end

  def pattern
    @datasrc['pattern']
  end
end # class DataSrc

# DataFiles
class DataFiles
  # Accepts a single String, Hash, or Array
  # String must be a filename
  # Hash must contain :file and optionally :type and :pattern
  # Array must contain filenames as strings
  # Returns array of DataSrc objects
  def initialize data_sources
    @data_sources = []
    if data_sources.is_a? Array
      data_sources.each do |src|
        @data_sources << DataSrc.new(src)
      end
    else # data_sources is String or Hash
      @data_sources[0] = DataSrc.new(data_sources)
    end
    @src_class = data_sources.class
  end

  def sources
    @data_sources
  end

  def type
    # returns the original class of the object used to init this obj
    @src_class
  end

end

class DataObj
  # DataObj
  #
  # Scoped variables for feeding a Liquid parsing operation
  def initialize
    @data = {"vars" => {}}
  end

  def add_data! data, scope=""
    # Merges data into existing scope or creates a new scope
    if scope.empty? # store new object at root of this object
      self.data.merge!data
    else # store new object as a subordinate, named object
      if self.data.key?(scope) # merge into existing key
        self.data[scope].merge!data
      else # create a new key named after the scope
        scoped_hash = { scope => data }
        self.data.merge!scoped_hash
      end
    end
  end

  def data
    @data
  end

  def remove_scope scope
    self.data.delete(scope)
  end

end

class AsciiDocument
  def initialize index, type='article'
    @index = index
    @attributes = {} # We start with clean attributes to delay setting those in the config > build step
    @type = type
  end

  def index
    @index
  end

  # NOTE this section repeats in Class.AsciiDocument
  def add_attrs! attrs
    raise "InvalidAttributesFormat" unless attrs.is_a?(Hash)
    self.attributes.merge!attrs
  end

  def attributes
    @attributes
  end

  def type
    @type
  end
end

# ===
# Action-specific procs
# ===
# PARSE-type build procs
# ===

# Pull in a semi-structured data file, converting contents to a Ruby hash
def ingest_data datasrc
  raise "InvalidDataSrcObject" unless datasrc.is_a? DataSrc
  case datasrc.type
  when "yml"
    begin
      data = YAML.load_file(datasrc.file)
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "json"
    begin
      data = JSON.parse(File.read(datasrc.file))
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "xml"
    begin
      data = Crack::XML.parse(File.read(datasrc.file))
      data = data['root']
    rescue Exception => ex
      @logger.error "There was a problem with the data file. #{ex.message}"
    end
  when "csv"
    data = []
    i = 0
    begin
      CSV.foreach(datasrc.file, headers: true, skip_blanks: true) do |row|
        data[i] = row.to_hash
        i = i+1
      end
    rescue
      @logger.error "The CSV format is invalid."
    end
  when "regex"
    if datasrc.pattern
      data = parse_regex(datasrc.file, datasrc.pattern)
    else
      @logger.error "You must supply a regex pattern with your free-form data file."
      raise "MissingRegexPattern"
    end
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
    output = records
  rescue Exception => ex
    @logger.error "Something went wrong trying to parse the free-form file. #{ex.class} thrown. #{ex.message}"
    raise "Freeform parse error"
  end
  return output
end

# Parse given data using given template, generating given output
def liquify data_obj, template_file, output
  validate_file_input(template_file, "template")
  # inject :includes_dirs as needed
  data_obj.add_data!(@includes_dirs, :includes_dirs) unless data_obj.data[:includes_dirs]
  begin
    template = File.read(template_file) # reads the template file
    template = Liquid::Template.parse(template) # compiles template
    rendered = template.render(data_obj.data) # renders the output
  rescue Exception => ex
    message = "Problem rendering Liquid template. #{template_file}\n" \
      "#{ex.class} thrown. #{ex.message}"
    @logger.error message
    raise message
  end
  unless output.downcase == "stdout"
    output_file = output
    generate_file(rendered, output_file)
  else # if stdout
    puts "========\nOUTPUT: Rendered with template #{template_file}:\n\n#{rendered}\n"
  end
end

def cli_liquify data_file=nil, template_file=nil, includes_dirs=nil, output_file=nil, passed_vars
  # converts command-line options into liquify or regurgidata inputs
  data_obj = DataObj.new()
  if data_file
    df = DataFiles.new(data_file)
    ingested = ingest_data(df.sources[0])
    data_obj.add_data!(ingested)
  end
  if template_file # process with Liquid
    includes_dirs = @includes_dirs unless includes_dirs
    data_obj.add_data!(ingested, "data") if df
    data_obj.add_data!(passed_vars, "vars") if passed_vars
    liquify(data_obj, template_file, output_file)
  else # direct conversion; dump passed vars in root
    data_obj.remove_scope("vars")
    data_obj.add_data!(passed_vars) if passed_vars
    regurgidata(data_obj, output_file)
  end
end

def regurgidata data_obj, output
  # converts data files from one format directly to another
  raise "UnrecognizedFileExtension" unless File.extname(output).match(/\.yml|\.json|\.xml|\.csv/)
  case File.extname(output)
    when ".yml"
      new_data = data_obj.data.to_yaml
    when ".json"
      new_data = data_obj.data.to_json
    when ".xml"
      @logger.warn "XML output not yet implemented."
    when ".csv"
      @logger.warn "CSV output not yet implemented."
  end
  if new_data
    begin
      generate_file(new_data, output)
      @logger.info "Data converted and saved to #{output}."
    rescue Exception => ex
      @logger.error "#{ex.class}: #{ex.message}"
      raise "FileWriteError"
    end
  end
end

# ===
# MIGRATE-type procs
# ===

# Copy images and other files into target dir
def copy_assets src, dest, inclusive=true, missing='exit'
  unless File.file?(src)
    unless inclusive then src = src + "/." end
  end
  src_to_dest = "#{src} to #{dest}"
  unless (File.file?(src) || File.directory?(src))
    case missing
    when "warn"
      @logger.warn "Skipping migrate action (#{src_to_dest}); source not found."
      return
    when "skip"
      @logger.debug "Skipping migrate action (#{src_to_dest}); source not found."
      return
    when "exit"
      @logger.error "Unexpected missing source in migrate action (#{src_to_dest})."
      raise "MissingSourceExit"
    end
  end
  @logger.debug "Copying #{src_to_dest}"
  begin
    FileUtils.mkdir_p(dest) unless File.directory?(dest)
    if File.directory?(src)
      FileUtils.cp_r(src, dest)
    else
      FileUtils.cp(src, dest)
    end
    @logger.info "Copied #{src} to #{dest}."
  rescue Exception => ex
    @logger.error "Problem while copying assets. #{ex.message}"
    raise
  end
end

# ===
# RENDER-type procs
# ===

# Gather attributes from one or more fixed attributes files
def ingest_attributes attr_file
  attr_files_array = attr_file.force_array
  attrs = {}
  attr_files_array.each do |f|
    if f.include? ":"
      file = f.split(":")
      filename = file[0]
      block_name = file[1]
    else
      filename = f
      block_name = false
    end
    validate_file_input(filename, "attributes")
    begin
      new_attrs = YAML.load_file(filename)
      if block_name
        begin
          new_attrs = new_attrs[block_name]
        rescue
          raise "InvalidAttributesBlock (#{filename}:#{block_name})"
        end
      end
    rescue Exception => ex
      @logger.error "Attributes block invalid. #{ex.class}: #{ex.message}"
      raise "AttributeBlockError"
    end
    begin
      if new_attrs.is_a? Hash
        attrs.merge!new_attrs
      else
        @logger.warn "The AsciiDoc attributes file #{filename} is not formatted as a hash, so its data was not ingested."
      end
    rescue Exception => ex
      raise "AttributesMergeError #{ex.message}"
    end
  end
  return attrs
end

def derive_backend type, out_file
  case File.extname(out_file)
  when ".pdf"
    backend = "pdf"
  else
    backend = "html5"
  end
  return backend
end

def render_doc doc, build
  case build.backend
  when "html5", "pdf"
    asciidocify(doc, build)
  when "jekyll"
    generate_site(doc, build)
  else
    raise "UnrecognizedBackend"
  end
end

def asciidocify doc, build
  @logger.debug "Executing Asciidoctor render operation for #{build.output}."
  to_file = build.output
  unless doc.type == build.doctype
    if build.doctype.nil? # set a default doctype equal to our LiquiDoc action doc type
      build.set("doctype", doc.type)
    end
  end
  # unfortunately we have to treat attributes accumilation differently for Jekyll vs Asciidoctor
  attrs = doc.attributes # Start with attributes added at the action level; no more writing to doc obj
  # Handle properties files array as attributes files and
  # add the ingested attributes to local var
  begin
    if build.prop_files_array
      ingested = ingest_attributes(build.prop_files_array)
      attrs.merge!(ingested)
    else
      puts build.prop_files_array
    end
  rescue Exception => ex
    @logger.warn "Attributes failed to merge. #{ex}" # Shd only trigger if build.props exists
    raise
  end
  if build.backend == "html5" # Insert a stylesheet
    attrs.merge!({"stylesheet"=>build.style}) if build.style
  end
  # Add attributes from config file build section
  attrs.merge!(build.attributes) # Finally merge attributes from the build step
  # Add attributes from command-line -a args
  @logger.debug "Final pre-Asciidoctor attributes: #{attrs.to_yaml}"
  # Perform the aciidoctor convert
  if build.backend == "pdf"
    @logger.info "Generating PDF. This can take some time..."
  end
  Asciidoctor.convert_file(
    doc.index,
    to_file: to_file,
    attributes: attrs,
    require: "pdf",
    backend: build.backend,
    doctype: build.doctype,
    safe: "unsafe",
    sourcemap: true,
    verbose: @verbose,
    mkdirs: true
  )
  @logger.info "Rendered file #{to_file}."
end

def generate_site doc, build
  case build.backend
  when "jekyll"
    attrs = doc.attributes
    build.add_config_file("_config.yml") unless build.prop_files_array
    jekyll = load_jekyll_data(build) # load the first Jekyll config file locally
    attrs.merge! ({"base_dir" => jekyll['source']}) # Sets default Asciidoctor base_dir to == Jekyll root
    # write all AsciiDoc attributes to a config file for Jekyll to ingest
    attrs.merge!(build.attributes) if build.attributes
    attrs = {"asciidoctor" => {"attributes" => attrs} }
    attrs_yaml = attrs.to_yaml # Convert it all back to Yaml, as we're going to write a file to feed back to Jekyll
    File.open("#{@build_dir}/pre/_attributes.yml", 'w') { |file| file.write(attrs_yaml) }
    build.add_config_file("#{@build_dir}/pre/_attributes.yml")
    config_list = build.prop_files_array.join(',') # flatten the Array back down for the CLI
    quiet = "--quiet" if @quiet || @explicit
    if build.props['arguments']
      opts_args_file = "#{@build_dir}/pre/jekyll_opts_args.yml"
      opts_args = build.props['arguments']
      File.open(opts_args_file, 'w') { |file|
      file.write(opts_args.to_yaml)}
      config_list << ",#{opts_args_file}"
    end
    base_args = "--config #{config_list}"
    command = "bundle exec jekyll build #{base_args} #{quiet}"
    if @search_index
      # TODO enable config-based admin api key ingest once config is dynamic
      command = algolia_index_cmd(build, @search_api_key, base_args)
      @logger.warn "Search indexing failed." unless command
    end
  end
  if command
    @logger.info "Running #{command}"
    @logger.debug "Final pre-jekyll-asciidoc attributes: #{doc.attributes.to_yaml} "
    system command
  end
  jekyll_serve(build) if @jekyll_serve
end

def load_jekyll_data build
  data = {}
  build.prop_files_array.each do |file|
    settings = YAML.load_file(file)
    data.merge!settings if settings
  end
  return data
end

# ===
# DEPLOY procs
# ===

def jekyll_serve build
  # Locally serve Jekyll as per the primary Jekyll config file
  @logger.debug "Attempting Jekyll serve operation."
  config_file = build.props['files'][0]
  if build.props['arguments']
    opts_args = build.props['arguments'].argify
  end
  command = "bundle exec jekyll serve --config #{config_file} #{opts_args} --no-watch --skip-initial-build"
  system command
end

def algolia_index_cmd build, apikey=nil, args
  unless build.search and build.search['index']
    @logger.warn "No index configuration found for build; jekyll-algolia operation skipped for this build."
    return false
  else
    unless apikey
      @logger.warn "No Algolia admin API key passed; skipping jekyll-algolia operation for this build."
      return false
    else
      return "ALGOLIA_INDEX_NAME='#{build.search['index']}' ALGOLIA_API_KEY='#{apikey}' bundle exec jekyll algolia #{@search_index_dry} #{args} "
    end
  end
end

# ===
# Execute
# ===

def execute_command cmd
  stdout, stderr, status = Open3.capture3(cmd.command)
  failed = true if status.to_s.include?("exit 1")
  unless cmd.options
    puts stdout
    puts stderr if failed
  else
    if failed && cmd.options['error']
      @logger.warn cmd.options['error']['message'] if cmd.options['error']['message']
      if cmd.options['error']['response'] == "exit"
        @logger.error "Command failure: #{stderr}"
        raise "CommandExecutionException"
      end
    end
    if cmd.options['outfile']
      contents = stdout
      if cmd.options['outfile']
        contents = "#{cmd.options['outfile']['prepend']}\n#{stdout}" if cmd.options['outfile']['prepend']
        contents = "#{stdout}/n#{cmd.options['outfile']['append']}" if cmd.options['outfile']['append']
        generate_file(contents, cmd.options['outfile']['path'])
      end
      if cmd.options['stdout']
        puts stdout
      end
    end
  end
end

# ===
# Text manipulation Classes, Modules, procs, etc
# ===

module ForceArray
  # So we can accept a list string ("item1.yml,item2.yml") or a single item ("item1.yml")
  # and convert to array as needed
  def force_array
    obj = self
    unless obj.class == Array
      if obj.class == String
        if obj.include? ","
          obj = obj.split(",") # Will even force a string with no commas to a 1-item array
        else
          obj = Array.new.push(obj)
        end
      else
        if obj.class == Hash
          obj = obj.to_array
        else
          raise "ForceArrayFail"
        end
      end
    end
    return obj.to_ary
  end

  def force_array!
    self.force_array
  end

end

class String
  include ForceArray
  include WordWrap

# Adapted from Nikhil Gupta
# http://nikhgupta.com/code/wrapping-long-lines-in-ruby-for-display-in-source-files/
  def wwrap width=76, prepend=''
    self.wrap(width)
    # self.prepend_lines(prepend)
    # commentchar = options.fetch(:commentchar, '')
    # width = options.fetch(:width, 76) - commentchar.size
    # self.strip.split("\n").collect do |line|
    #   line.gsub(/^(\s+)?#{commentchar}(.*)$/, '\\2')
    #   line.gsub(/(.{1,#{width}})(\s+|$)/, "\\1\n") if line.length > width
    #   line.gsub(/^(.*)$/, "#{commentchar}\\1")
    #
    # end
    #
  end

  def prepend_lines chars
    spaces = chars.size
    self.each_line do |l|
      l.gsub(/^/, spaces).gsub(/^\s*$/, '')
    end
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

  def contains_liquid?
    self.each_line do |row|
      if row.match(/.*\{\%.*\%\}.*|.*\{\{.*\}\}.*/)
        return true
      end
    end
    return false
  end

  def quote_wrap quotes="double", pattern="space"
    # When a string contains certain chars, wrap it in certain quotes
    # Pass 'double', 'single', or a pair of chars to quotes arg
    # Pass 'space' as pattern to wrap any string that contains 1 or more spaces
    pattern = "\s" if pattern == "space"
    if quotes.size > 2
      case quotes
      when "double"
        quotes = '""'
      when "single"
        quotes = "''"
      else
        quotes = "«»"
      end
    end
    return self unless self.match(/#{pattern}/)
    unless quotes.size != 2 # quotes must be a pair of chars
      q1 = quotes[0]
      q2 = quotes[1]
      return self.prepend(q1).append(q2)
    end
  end

end

class Array
  include ForceArray

  def to_hash
    struct = {}
    self.each do |p|
      struct.merge!p if p.is_a? Hash
    end
    return struct
  end

  def uniq_prop_list_item_vals_glob? property
    # testing for uniquenes globally among all values in subarrays (list-formatted values) of all instances of the property across all nodes in the parent array
    #
    # Example:
    #   array_of_hashes[0]['cue'] = ['one','two','three']
    #   array_of_hashes[1]['cue'] = ['three','four','five']
    #   array_of_hashes.uniq_prop_vals_globally?('cue')
    #   #=> false
    #   Due to the apperance of 'three' in both instances of cue.

  end

end

class Hash
  include ForceArray

  def to_array op=nil
    # Converts a hash of key-value pairs to a flat array based on the first tier
    out = []
    self.each do |k,v|
      v = "<RemovedObject>" if v.is_a? Enumerable and op == "flatten"
      out << {k => v}
    end
    return out
  end

  def argify template, delim
    # Converts a hash of key-value pairs to command-line option/argument listings
    # Can be called with optional arguments:
    # template :: Liquid-formatted parsing template string
    #          Accepts:
    #
    #            'hyph'            :: -<key> <value>
    #            'hyphhyph'        :: --<key> <value> (default)
    #            'hyphchar'        :: -<k> <value>
    #            'dump'            :: <key> <value>
    #            'paramequal'      :: <key>=<value>
    #            'valonly'         :: <value>
    # delim    :: Delimiter -- any ASCII characters that separate the arguments
    #
    # For template-based usage, express the variables:
    #    opt (the keyname) as {{opt}}
    #    arg (the value) as {{arg}}
    # EXAMPLES (my_hash = {"key1"=>"val1", "key2"=>"val2"})
    # my_hash.argify                      #=> key1 val1 key2 val2
    # my_hash.argify('hyphhyph')          #=> --key1 val1 --key2 val2
    # my_hash.argify('hyphchar')          #=> -k val1 -k val2
    # my_hash.argify('paramequal')        #=> key1=val1 key2=val2
    # my_hash.argify('-a {{opt}}={{arg}}')#=> -a key1=val1 -a key2=val2
    # my_hash.argify('liquid', ' ', "{{opt}} `{{arg}}`")
    #                                          #=> key1 `val1` key2 `val2`
    # my_hash.argify('valonly', '||')     #=> val1||val2
    # raise "InvalidObject" unless self.is_a? Hash

    if template.contains_liquid?
      tp = template # use the passed Liquid template
    else
      case template # use a preset Liquid template by name
      when "dump"
        tp = "{{opt}} {{arg}}"
      when "hyph"
        tp = "-{{opt}} {{arg}}"
      when "hyphhyph"
        tp = "--{{opt}} {{arg}}"
      when "hyphchar"
        tp = "-{{ opt | downcase | split: '' | first }} {{arg}}"
      when "paramequal"
        tp = "{{opt}}={{arg}}"
      when "valonly"
        tp = "{{arg}}"
      else
        return "Liquid: Unrecognized argify template name"
      end
    end
    begin
      tpl = Liquid::Template.parse(tp)
      first = true
      out = ''
      self.each do |k,v|
        # establish datasource
        v = v.quote_wrap(" ") if v.is_a? String
        v = "<Object>" if v.is_a? Enumerable
        input = {"opt" => k, "arg" => v }
        if first
          dlm = ""
          first = false
        else
          dlm = delim
        end
        out += dlm + tpl.render(input)
      end
    rescue
      raise "Argify template processing failed"
    end
    return out
  end

end

# Extending Liquid filters/text manipulation
module CustomFilters
  #
  # LiquiDoc custom filters
  #
  def wwrap input, width=76
    input.wwrap
  end

  def plainwrap input
    input.wwrap
  end
  def commentwrap input, token='# '
    input.wwrap
  end
  def unwrap input # Not fully functional; inserts explicit '\n'
    if input
      token = "[g59hj1k]"
      input.gsub(/\n\n/, token).gsub(/\n/, ' ').gsub(token, "\n\n")
    end
  end

  def regexreplace input, regex, replacement=''
    input.to_s.gsub(Regexp.new(regex), replacement.to_s)
  end

  # replacement for Jekyll's slugify
  def slugify input, bridge="-", snip=true
    s = input.to_s.downcase
    s.gsub!(/[^a-z0-9]/, bridge)
    if snip
      while s.match("--")
        s.gsub!("--", "-")
      end
      s.gsub!(/^-(.*)$/, "\\1")
      s.gsub!(/^(.*)\-$/, "\\1")
    end
    s
  end

  #
  # sterile-based filters
  #

  def to_slug input, delim='-'
    o = input.dup
    opts = {:delimiter=>delim}
    o.to_slug(opts)
  end

  def transliterate input
    o = input.dup
    o.transliterate
  end

  def smart_format input
    o = input.dup
    o.smart_format
  end

  def encode_entities input
    o = input.dup
    o.encode_entities
  end

  def titlecase input
    o = input.dup
    o.titlecase
  end

  def strip_tags input
    o = input.dup
    o.strip_tags
  end

  def sterilize input
    o = input.dup
    o.sterilize
  end

  # Get all unique values for each item in an array, or each unique value of a desigated
  #  parameter in an array of hashes.
  #
  # @input    : the object array
  # @property : (optional) parameter in which to select unique values (for hashes)
  def uniq_prop_vals input, property=nil, global=false
    return input unless input.is_a?(Array)
    unless property
      out = input.uniq
    else
      new_ary = input.uniq { |i| i[property] }
      out = new_ary.map { |i| i[property] }.compact
    end
    out
  end

  def asciidocify input
    Asciidoctor.convert(input, doctype: "inline")
  end

  def to_cli_args input, tpl="paramequal", delim=" "
    o = input.dup
    o.argify(tpl, delim)
  end

  def hash_to_array input, op=nil
    o = input.dup
    o.to_array(op)
  end

  def holds_liquid input
    o = false
    o = true if input.contains_liquid?
    o
  end

end

# Register custom Liquid filters
Liquid::Template.register_filter(CustomFilters)

# ===
# Command/options parser
# ===

# Define command-line option/argument parameters
# From the root directory of your project:
# $ liquidoc --help
command_parser = OptionParser.new do|opts|
  opts.banner = "Usage: liquidoc [options]"

  opts.on("-a KEY=VALUE", "For passing an AsciiDoc attribute parameter to Asciidoctor. Ex: -a imagesdir=some/path -a custom_var='my value'") do |n|
    pair = {}
    k,v = n.split('=')
      pair[k] = v
    @passed_attrs.merge!pair
  end

  # Global Options
  opts.on("-b PATH", "--base PATH", "The base directory, relative to this script. Defaults to `.`, or pwd." ) do |n|
    @base_dir = n
  end

  opts.on("-B PATH", "--build PATH", "The directory under which LiquiDoc should save automatically preprocessed files. Defaults to #{@base_dir}_build. Can be absolute or relative to the base path (-b/--base=). Do NOT append '/' to the build path." ) do |n|
    @build_dir = n
  end

  opts.on("-c", "--config PATH", "Configuration file, enables preset source, template, and output.") do |n|
    @config_file = @base_dir + n
  end

  opts.on("-d PATH[,PATH]", "--data PATH[,PATH]", "Semi-structured data source (input) path. Ex. -d path/to/data.yml. Required unless --config is called." ) do |n|
    @data_file = @base_dir + n
  end

  opts.on("-f PATH", "--from PATH", "Directory to copy assets from." ) do |n|
    @attributes_file = n
  end

  opts.on("-i PATH", "--index PATH", "An AsciiDoc index file for mapping an Asciidoctor build." ) do |n|
    @index_file = n
  end

  opts.on("-o PATH", "--output PATH", "Output file path for generated content. Ex. path/to/file.adoc. Required unless --config is called.") do |n|
    @output_file = @base_dir + n
  end

  opts.on("-t PATH", "--template PATH", "Path to liquid template. Required unless --configuration is called." ) do |n|
    @template_file = @base_dir + n
  end

  opts.on("--includes PATH[,PATH]", "Paths to directories where includes (partials) can be found." ) do |n|
    n.force_array!
    # puts n.class
    # n.map { |p| @base_dir + p }
    @includes_dirs = n
  end

  opts.on("--verbose", "Run verbose debug logging.") do |n|
    @logger.level = Logger::DEBUG
    @verbose = true
  end

  opts.on("--quiet", "Run with only WARN- and error-level logs written to console.") do |n|
    @logger.level = Logger::WARN
    @quiet = true
  end

  opts.on("--explain", "Log explicit step descriptions to console as build progresses. (Otherwise writes to file at #{@build_dir}/pre/config-explainer.adoc .)") do |n|
    explainer_init("STDOUT")
    @explainer.level = Logger::INFO
    @logger.level = Logger::WARN # Suppress all those INFO-level messages
    @explicit = true
  end

  opts.on("--stdout", "Puts the output in STDOUT instead of writing to a file.") do
    @output_type = "stdout"
  end

  opts.on("--deploy", "EXPERIMENTAL: Trigger a jekyll serve operation against the destination dir of a Jekyll render step.") do
    @jekyll_serve = true
  end

  opts.on("--search-index-push", "Runs any search indexing configured in the build step and pushes to Algolia.") do
    @search_index = true
  end

  opts.on("--search-index-dry", "Runs any search indexing configured in the build step but does NOT push to Algolia.") do
    @search_index = true
    @search_index_dry = "--dry-run"
  end

  opts.on("--search-api-key=STRING", "Passes Algolia Admin API key (which you should keep out of Git).") do |n|
    @search_api_key = n
  end

  opts.on("-v", "--var KEY=VALUE", "For passing variables directly to the 'vars.' scope of a template; for dynamic configs, too.") do |n|
    pair = {}
    k,v = n.split('=')
      pair[k] = v
    @passed_vars.merge!pair
  end

  opts.on("--parse-config", "Preprocess the designated configuration file as a Liquid template. Superfluous when passing -v/--var arguments.") do
    @parseconfig = true
  end

  opts.on("--unsafe", "Enable shell command executions without interactive check.") do
    @safemode = false
  end

  opts.on("-h", "--help", "Returns help.") do
    puts opts
    exit
  end

end

command_parser.parse!

# Upfront debug output
@logger.debug "Base dir: #{@base_dir} (The path from which LiquiDoc CLI commands are relative.)"

explainer_init

# ===
# Execute
# ===

unless @config_file
  @logger.debug "Executing config-free build based on API/CLI arguments alone."
  if @data_file
    cli_liquify(@data_file, @template_file, @includes_dirs, @output_file, @passed_vars)
  end
  if @index_file
    @logger.warn "Rendering via command line arguments is not yet implemented. Use a config file."
  end
else
  @logger.debug "Executing... config_build"
  config_build(@config_file, @passed_vars, @parseconfig)
end
