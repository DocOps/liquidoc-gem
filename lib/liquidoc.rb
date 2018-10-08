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
require 'jekyll'

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
# 6. text manipulation modules/classes def
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
@data_dir = @base_dir + '_data/'
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
  validate_file_input(config_file, "config")
  if config_vars.length > 0 or parse or contains_liquid(config_file)
    @logger.debug "Config_vars: #{config_vars.length}"
  # If config variables are passed on the CLI, we want to parse the config file
  # and use the parsed version for the rest fo this routine
    config_out = "#{@build_dir}/pre/#{File.basename(config_file)}"
    liquify(nil,config_file, config_out, config_vars)
    config_file = config_out
    @logger.debug "Config parsed! Using #{config_out} for build."
    validate_file_input(config_file, "config")
  end
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
  cfg = BuildConfig.new(config) # convert the config file to a new object called 'cfg'
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
      if step.data
        data = DataSrc.new(step.data)
      end
      builds = step.builds
      builds.each do |bld|
        build = Build.new(bld, type) # create an instance of the Build class; Build.new accepts a 'bld' hash & action 'type'
        if build.template
          @explainer.info build.message
          build.add_vars!(@passed_vars) unless @passed_vars.empty?
          liquify(data, build.template, build.output, build.variables) # perform the liquify operation
        else
          regurgidata(data, build.output)
        end
      end
    when "migrate"
      inclusive = true
      inclusive = step.options['inclusive'] if defined?(step.options['inclusive'])
      copy_assets(step.source, step.target, inclusive)
    when "render"
      validate_file_input(step.source, "source") if step.source
      builds = step.builds
      for bld in builds
        doc = AsciiDocument.new(step.source)
        attrs = ingest_attributes(step.data) if step.data # Set attributes from from YAML files
        doc.add_attrs!(attrs) # Set attributes from the action-level data file
        build = Build.new(bld, type) # create an instance of the Build class; Build.new accepts a 'bld' hash & action 'type' string
        build.set("backend", derive_backend(doc.type, build.output) ) unless build.backend
        @explainer.info build.message
        render_doc(doc, build) # perform the render operation
      end
    when "deploy"
      @logger.warn "Deploy actions are limited and experimental."
      jekyll_serve(build)
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

def contains_liquid filename
  File.open(filename, "r") do |file_proc|
    file_proc.each_line do |row|
      if row.match(/.*\{\%.*\%\}.*|.*\{\{.*\}\}.*/)
        return true
      end
    end
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

end #class BuildConfig

class BuildConfigStep

  def initialize step
    @step = step
    if (defined?(@step['action'])).nil?
      raise "ConfigStructError"
    end
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
    end
    for req in reqs
      if (defined?(@step[req])).nil?
        @logger.error "Every #{@step['action']}-type in the configuration file needs a '#{req}' declaration."
        raise "ConfigStructError"
      end
    end
  end

end #class Action

class Build

  def initialize build, type
    build['attributes'] = Hash.new unless build['attributes']
    build['props'] = build['properties'] if build['properties']
    @build = build
    @type = type
    @build['variables'] = {} unless @build['variables']
  end

  def template
    @build['template']
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
    @build['variables']
  end

  def add_vars! vars
      vars.to_h unless vars.is_a? Hash
      self.variables.merge!vars
  end

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

  # def prop_files_list # force the array back to a list of files (for CLI)
  #   props['files'].force_array if props['files']
  # end

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
    for req in required
      if (defined?(req)).nil?
        raise "ActionSettingMissing"
      end
    end
  end

end # class Build

class DataSrc
  # initialization means establishing a proper hash for the 'data' param
  def initialize datasrc
    @datasrc = {}
    @datasrc['file'] = datasrc
    @datasrc['ext'] = ''
    @datasrc['type'] = false
    @datasrc['pattern'] = false
    if datasrc.is_a? Hash # data var is a hash, so add 'ext' to it by extracting it from filename
      @datasrc['file'] = datasrc['file']
      @datasrc['ext'] = File.extname(datasrc['file'])
      if (defined?(datasrc['pattern']))
        @datasrc['pattern'] = datasrc['pattern']
      end
      if (defined?(datasrc['type']))
        @datasrc['type'] = datasrc['type']
      end
    else
      if datasrc.is_a? String
        @datasrc['ext'] = File.extname(datasrc)
      else
        if datasrc.is_a? Array

        else
          raise "InvalidDataSource"
        end
      end
    end
  end

  def file
    @datasrc['file']
  end

  def ext
    @datasrc['ext']
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
      datatype = @datasrc['ext']
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

class AsciiDoctorConfig
  def initialize  out, type, back

  end
end

# ===
# Action-specific procs
# ===
# PARSE-type build procs
# ===

# Get data
def get_data datasrc
  @logger.debug "Executing liquify parsing operation."
  if datasrc.is_a? String
    datasrc = DataSrc.new(datasrc)
  end
  validate_file_input(datasrc.file, "data")
  return ingest_data(datasrc)
end

# Pull in a semi-structured data file, converting contents to a Ruby hash
def ingest_data datasrc
  raise "InvalidDataObject" unless datasrc.is_a? Object
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
  if data.is_a? Array
    data = {"data" => data}
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
def liquify datasrc, template_file, output, variables=nil
  if datasrc
    input = get_data(datasrc)
    nested = { "data" => get_data(datasrc)}
    input.merge!nested
  end
  if variables
    if input
      input.merge!variables
    else
      input = variables
    end
  end
  @logger.error "Parse operations need at least a data file or variables." unless input
  validate_file_input(template_file, "template")
  if variables
    vars = { "vars" => variables }
    input.merge!vars
  end
  begin
    template = File.read(template_file) # reads the template file
    template = Liquid::Template.parse(template) # compiles template
    rendered = template.render(input) # renders the output
  rescue Exception => ex
    message = "Problem rendering Liquid template. #{template_file}\n" \
      "#{ex.class} thrown. #{ex.message}"
    @logger.error message
    raise message
  end
  unless output.downcase == "stdout"
    output_file = output
    base_path = File.dirname(output)
    begin
      FileUtils::mkdir_p(base_path) unless File.exists?(base_path)
      File.open(output_file, 'w') { |file| file.write(rendered) } # saves file
    rescue Exception => ex
      @logger.error "Failed to save output.\n#{ex.class} #{ex.message}"
      raise "FileNotBuilt"
    end
    if File.exists?(output_file)
      @logger.info "File built: #{output_file}"
    else
      @logger.error "Hrmp! File not built."
      raise "FileNotBuilt"
    end
  else # if stdout
    puts "========\nOUTPUT: Rendered with template #{template_file}:\n\n#{rendered}\n"
  end
end

def regurgidata datasrc, output
  data = get_data(datasrc)
  raise "UnrecognizedFileExtension" unless File.extname(output).match(/\.yml|\.json|\.xml|\.csv/)
  case File.extname(output)
    when ".yml"
      new_data = data.to_yaml
    when ".json"
      new_data = data.to_json
    when ".xml"
      @logger.warn "XML output not yet implemented."
    when ".csv"
      @logger.warn "CSV output not yet implemented."
  end
  if new_data
    begin
      File.open(output, 'w') { |file| file.write(new_data) }
      @logger.info "Data converted and saved to #{output}."
    rescue
      raise "FileWriteError"
    end
  end
end

# ===
# MIGRATE-type procs
# ===

# Copy images and other files into target dir
def copy_assets src, dest, inclusive=true
  unless File.file?(src)
    unless inclusive then src = src + "/." end
  end
  @logger.debug "Copying #{src} to #{dest}"
  begin
    FileUtils.mkdir_p(dest) unless File.directory?(dest)
    if File.directory?(src)
      FileUtils.cp_r(src, dest)
    else
      FileUtils.cp(src, dest)
    end
    @logger.info "Copied #{src} to #{dest}."
  rescue Exception => ex
    @logger.warn "Problem while copying assets. #{ex.message}"
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
          raise "InvalidAttributesBlock"
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
    opts_args = build.props['arguments'].to_opts_args
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
# Text manipulation Classes, Modules, procs, etc
# ===

module HashMash

  def to_opts_args
    out = ''
    if self.is_a? Hash # TODO Should also be testing for flatness
      self.each do |opt,arg|
        out = out + " --#{opt} #{arg}"
      end
    end
    return out
  end

end

class Hash
  include HashMash
end

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
        raise "ForceArrayFail"
      end
    end
    return obj.to_ary
  end

end

class String
  include ForceArray
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

class Array
  include ForceArray
end

# Extending Liquid filters/text manipulation
module CustomFilters
  include Jekyll::Filters

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

  def slugify input
    # Downcase
    # Turn unwanted chars into the seperator
    s = input.to_s.downcase
    s.gsub!(/[^a-zA-Z0-9\-_\+\/]+/i, "-")
    s
  end

  def regexreplace input, regex, replacement=''
    input.to_s.gsub(Regexp.new(regex), replacement.to_s)
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

  opts.on("-a KEY=VALUE", "For passing an AsciiDoc attribute parameter to Asciidoctor. Ex: -a imagesdir=some/path -a custom_var='my value'") do |n|
    pair = {}
    k,v = n.split('=')
      pair[k] = v
    @passed_attrs.merge!pair
  end

  # Global Options
  opts.on("-b PATH", "--base=PATH", "The base directory, relative to this script. Defaults to `.`, or pwd." ) do |n|
    @base_dir = n
  end

  opts.on("-B PATH", "--build=PATH", "The directory under which LiquiDoc should save automatically preprocessed files. Defaults to #{@base_dir}_build. Can be absolute or relative to the base path (-b/--base=). Do NOT append '/' to the build path." ) do |n|
    @build_dir = n
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
    liquify(@data_file, @template_file, @output_file, @passed_vars)
  end
  if @index_file
    @logger.warn "Rendering via command line arguments is not yet implemented. Use a config file."
  end
else
  @logger.debug "Executing... config_build"
  config_build(@config_file, @passed_vars, @parseconfig)
end
