# (C) Jekyll, this file contains some of Jekyll's custom Liquid filters
# It is placed in lib/liquid/jekyll for this reason, even though the module/class
# path is Jekyll::Tags::, so as not to conflict with the Liquid:: path.

# frozen_string_literal: true

module Jekyll
  module Tags
    class IncludeTagError < StandardError
      attr_accessor :path

      def initialize(msg, path)
        super(msg)
        @path = path
      end
    end

    class IncludeTag < Liquid::Tag
      # matches proper params format only
      # 1(key-formatted str) = (2(double-quoted str) or 3(single-quoted str) 4(var-formatted str))
      VALID_SYNTAX = %r!
        ([\w-]+)\s*=\s*
        (?:"([^"\\]*(?:\\.[^"\\]*)*)"|'([^'\\]*(?:\\.[^'\\]*)*)'|([a-z][\w'"\[\]\.-]*))
      !x
      # extracts filename as #{variable} and k/v pairs as #{params}
      VARIABLE_SYNTAX = %r!
        (?<variable>[^{]*(\{\{\s*[\w\-\.]+\s*(\|.*)?\}\}[^\s{}]*)+)
        (?<params>.*)
      !mx

      FULL_VALID_SYNTAX = %r!\A\s*(?:#{VALID_SYNTAX}(?=\s|\z)\s*)*\z!
      VALID_FILENAME_CHARS = %r!^[\w/\.-]+$!
      INVALID_SEQUENCES = %r![./]{2,}!

      def initialize(tag_name, markup, tokens)
        super
        matched = markup.strip.match(VARIABLE_SYNTAX)
        if matched # include passes filename as variable
          @file = matched["variable"].strip # The file to include (as a var)
          @params = matched["params"].strip # The paired vars to load
        else # if the filename isn't a variable, just grab the first arg as filename and rest as params
          @file, @params = markup.strip.split(%r!\s+!, 2)
        end
        validate_params if @params
        @tag_name = tag_name
      end

      def syntax_example
        "{% #{@tag_name} file.ext param='value' param2='value' %}"
      end

      def parse_params(context)
        params = {}
        markup = @params
        while (match = VALID_SYNTAX.match(markup))
          # run until syntax no longer matches parameters
          markup = markup[match.end(0)..-1]
          # set val by which group matched in VALID_SYNTAX
          # either a quoted string (2,3) or a variable (4)
          value = if match[2]
                    match[2].gsub(%r!\\"!, '"')
                  elsif match[3]
                    match[3].gsub(%r!\\'!, "'")
                  elsif match[4] # val is resolved context var
                    context[match[4]]
                  end
          params[match[1]] = value # inserts param
        end
        params # returns hash for the include scope
      end

      def validate_file_name(file)
        if file =~ INVALID_SEQUENCES || file !~ VALID_FILENAME_CHARS
          raise ArgumentError, <<-MSG
Invalid syntax for include tag. File contains invalid characters or sequences:

  #{file}

Valid syntax:

  #{syntax_example}

MSG
        end
      end

      def validate_params
        unless @params =~ FULL_VALID_SYNTAX
          raise ArgumentError, <<-MSG
Invalid syntax for include tag:

  #{@params}

Valid syntax:

  #{syntax_example}

MSG
        end
      end

      # # Grab file read opts in the context
      # def file_read_opts(context)
      #   context.registers[:site].file_read_opts
      # end

      # Express the filename from the variable
      # Passes along the context in which it was called, from the parent file
      def render_variable(context)
        Liquid::Template.parse(@file).render(context) if @file =~ VARIABLE_SYNTAX
      end

      # Array of directories where includes are stored
      def tag_includes_dirs(context)
        # context[:includes_dirs]
        ['_templates','_templates/liquid']
      end

      # Traverse includes dirs, setting paths for includes
      def locate_include_file(context, file, safe)
        includes_dirs = tag_includes_dirs(context)
        includes_dirs.each do |dir|
          path = File.join(dir.to_s, file.to_s)
          return path if File.exist?(path)
        end
        raise IOError, could_not_locate_message(file, includes_dirs, safe)
      end

      # recall/render the included partial and place it in the parent doc
      def render(context)
        file = render_variable(context) || @file # use parsed variable filename unless passed explicit filename
        validate_file_name(file)
        path = locate_include_file(context, file, true) # ensure file exists in safe path
        return unless path
        # # ???????
        # add_include_to_dependency(site, path, context)
        #
        # Load the partial if it's identical to one we've already loaded ???
        partial = File.read(path) # reads the template file
        partial = Liquid::Template.parse(partial) # compiles template
        # setup and perform render
        context.stack do
          # create a hash object for any passed k/v pair args
          # by parsing passed parameters using the parent file's scope
          context["include"] = parse_params(context) if @params
          begin # render the include for output
            partial.render!(context)
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      # #
      # def add_include_to_dependency(site, path, context)
      #   if context.registers[:page] && context.registers[:page].key?("path")
      #     site.regenerator.add_dependency(
      #       site.in_source_dir(context.registers[:page]["path"]),
      #       path
      #     )
      #   end
      # end

      def load_cached_partial(path, context)
        context.registers[:cached_partials] ||= {}
        cached_partial = context.registers[:cached_partials]

        if cached_partial.key?(path)
          cached_partial[path]
        else
          unparsed_file = context.registers[:globals]
            .liquid_renderer
            .file(path)
          begin
            # Cache a version of the
            cached_partial[path] = unparsed_file.parse(read_file(path, context))
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      def outside_site_source?(path, dir, safe)
        safe && !realpath_prefixed_with?(path, dir)
      end

      def realpath_prefixed_with?(path, dir)
        File.exist?(path) && File.realpath(path).start_with?(dir)
      rescue StandardError
        false
      end

      # This method allows to modify the file content by inheriting from the class.
      def read_file(file, context)
        File.read(file)
      end

      private

      def could_not_locate_message(file, includes_dirs, safe)
        message = "Could not locate the included file '#{file}' in any of "\
          "#{includes_dirs}. Ensure it exists in one of those directories and"
        message + if safe
                    " is not a symlink as those are not allowed in safe mode."
                  else
                    ", if it is a symlink, does not point outside your site source."
                  end
      end
    end

  end # Tags

end

Liquid::Template.register_tag("include", Jekyll::Tags::IncludeTag)
Liquid::Template.register_tag("inc", Jekyll::Tags::IncludeTag)
