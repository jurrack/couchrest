require 'digest/md5'

module CouchRest
  class FileManager
    attr_reader :db
    attr_accessor :loud
    
    LANGS = {"rb" => "ruby", "js" => "javascript"}
    MIMES = {
      "html"  => "text/html",
      "htm"   => "text/html",
      "png"   => "image/png",
      "gif"   => "image/gif",
      "css"   => "text/css",
      "js"    => "test/javascript",
      "txt"   => "text/plain"
    }    
    def initialize(dbname, host="http://127.0.0.1:5984")
      @db = CouchRest.new(host).database(dbname)
    end
    
    def push_app(appdir, appname)
      libs = []
      viewdir = File.join(appdir,"views")
      attachdir = File.join(appdir,"_attachments")

      fields = dir_to_fields(appdir)
      package_forms(fields["forms"])
      package_views(fields["views"])

      docid = "_design/#{appname}"
      design = @db.get(docid) rescue {}
      design.merge!(fields)
      design['_id'] = docid
      # design['language'] = lang if lang
      @db.save(design)
      push_directory(attachdir, docid)
    end

    def push_directory(push_dir, docid=nil)
      docid ||= push_dir.split('/').reverse.find{|part|!part.empty?}

      pushfiles = Dir["#{push_dir}/**/*.*"].collect do |f|
        {f.split("#{push_dir}/").last => open(f).read}
      end

      return if pushfiles.empty?

      @attachments = {}
      @signatures = {}
      pushfiles.each do |file|
        name = file.keys.first
        value = file.values.first
        @signatures[name] = md5(value)

        @attachments[name] = {
          "data" => value,
          "content_type" => MIMES[name.split('.').last]
        } 
      end

      doc = @db.get(docid) rescue nil

      unless doc
        say "creating #{docid}"
        @db.save({"_id" => docid, "_attachments" => @attachments, "signatures" => @signatures})
        return
      end

      doc["signatures"] ||= {}
      doc["_attachments"] ||= {}
      # remove deleted docs
      to_be_removed = doc["signatures"].keys.select do |d| 
        !pushfiles.collect{|p| p.keys.first}.include?(d) 
      end 

      to_be_removed.each do |p|
        say "deleting #{p}"
        doc["signatures"].delete(p)
        doc["_attachments"].delete(p)
      end

      # update existing docs:
      doc["signatures"].each do |path, sig|
        if (@signatures[path] == sig)
          say "no change to #{path}. skipping..."
        else
          say "replacing #{path}"
          doc["signatures"][path] = md5(@attachments[path]["data"])
          doc["_attachments"][path].delete("stub")
          doc["_attachments"][path].delete("length")    
          doc["_attachments"][path]["data"] = @attachments[path]["data"]
          doc["_attachments"][path].merge!({"data" => @attachments[path]["data"]} )
        end
      end

      # add in new files
      new_files = pushfiles.select{|d| !doc["signatures"].keys.include?( d.keys.first) } 

      new_files.each do |f|
        say "creating #{f}"
        path = f.keys.first
        content = f.values.first
        doc["signatures"][path] = md5(content)

        doc["_attachments"][path] = {
          "data" => content,
          "content_type" => MIMES[path.split('.').last]
        }
      end

      begin
        @db.save(doc)
      rescue Exception => e
        say e.message
      end
    end
    
    # deprecated
    def push_views(view_dir)
      puts "WARNING this is deprecated, use `couchapp` script"
      designs = {}

      Dir["#{view_dir}/**/*.*"].each do |design_doc|
        design_doc_parts = design_doc.split('/')
        next if /^lib\..*$/.match design_doc_parts.last
        pre_normalized_view_name = design_doc_parts.last.split("-")
        view_name = pre_normalized_view_name[0..pre_normalized_view_name.length-2].join("-")

        folder = design_doc_parts[-2]

        designs[folder] ||= {}
        designs[folder]["views"] ||= {}
        design_lang = design_doc_parts.last.split(".").last
        designs[folder]["language"] ||= LANGS[design_lang]

        libs = ""
        Dir["#{view_dir}/lib.#{design_lang}"].collect do |global_lib|
          libs << open(global_lib).read
          libs << "\n"
        end
        Dir["#{view_dir}/#{folder}/lib.#{design_lang}"].collect do |global_lib|
          libs << open(global_lib).read
          libs << "\n"
        end
        if design_doc_parts.last =~ /-map/
          designs[folder]["views"][view_name] ||= {}
          designs[folder]["views"][view_name]["map"] = read(design_doc, libs)
        end

        if design_doc_parts.last =~ /-reduce/
          designs[folder]["views"][view_name] ||= {}
          designs[folder]["views"][view_name]["reduce"] = read(design_doc, libs)
        end
      end

      # cleanup empty maps and reduces
      designs.each do |name, props|
        props["views"].each do |view, funcs|
          next unless view.include?("reduce")
          props["views"].delete(view) unless funcs.keys.include?("reduce")
        end
      end
      
      designs.each do |k,v|
        create_or_update("_design/#{k}", v)
      end
      
      designs
    end
    
    def pull_views(view_dir)
      prefix = "_design"
      ds = db.documents(:startkey => '#{prefix}/', :endkey => '#{prefix}/ZZZZZZZZZ')
      ds['rows'].collect{|r|r['id']}.each do |id|
        puts directory = id.split('/').last
        FileUtils.mkdir_p(File.join(view_dir,directory))
        views = db.get(id)['views']

        vgroups = views.keys.group_by{|k|k.sub(/\-(map|reduce)$/,'')}
        vgroups.each do|g,vs|
          mapname = vs.find {|v|views[v]["map"]}
          if mapname
            # save map
            mapfunc = views[mapname]["map"]
            mapfile = File.join(view_dir, directory, "#{g}-map.js") # todo support non-js views
            File.open(mapfile,'w') do |f|
              f.write mapfunc
            end
          end

          reducename = vs.find {|v|views[v]["reduce"]}
          if reducename
            # save reduce
            reducefunc = views[reducename]["reduce"]
            reducefile = File.join(view_dir, directory, "#{g}-reduce.js") # todo support non-js views
            File.open(reducefile,'w') do |f|
              f.write reducefunc
            end
          end
        end
      end        
    end
    
    def dir_to_fields(dir)
      fields = {}
      (Dir["#{dir}/**/*.*"] - 
        Dir["#{dir}/_attachments/**/*.*"]).each do |file|
        farray = file.sub(dir, '').sub(/^\//,'').split('/')
        myfield = fields
        while farray.length > 1
          front = farray.shift
          myfield[front] ||= {}
          myfield = myfield[front]
        end
        fname, fext = farray.shift.split('.')
        fguts = File.open(file).read
        if fext == 'json'
          myfield[fname] = JSON.parse(fguts)
        else
          myfield[fname] = fguts
        end
      end
      return fields
    end
    
    
    # Generate an application in the given directory.
    # This is a class method because it doesn't depend on 
    # specifying a database.
    def self.generate_app(app_dir)      
      templatedir = File.join(File.expand_path(File.dirname(__FILE__)), 'template-app')
      FileUtils.cp_r(templatedir, app_dir)
    end
    
    private
    
    def package_forms(funcs)
      if funcs["lib"]
        lib = "var lib = #{funcs["lib"].to_json};"
        funcs.delete("lib")
        apply_lib(funcs, lib)
      end
    end
    
    def package_views(views)
      if views["_lib"]
        lib = "var lib = #{views["_lib"].to_json};"
        views.delete("_lib")
      end
      views.each do |view, funcs|
        apply_lib(funcs, lib) if lib
      end
    end
    
    def apply_lib(funcs, lib)
      funcs.each do |k,v|
        funcs[k] = v.sub(/(\/\/|#)\ ?include-lib/,lib)
      end
    end
    
    def say words
      puts words if @loud
    end
    
    def md5 string
      Digest::MD5.hexdigest(string)
    end
    
    # deprecated
    def read(file, libs=nil)
      st = open(file).read
      st.sub!(/(\/\/|#)include-lib/,libs) if libs
      st
    end
    
    def create_or_update(id, fields)
      existing = @db.get(id) rescue nil

      if existing
        updated = existing.merge(fields)
        if existing != updated
          say "replacing #{id}"
          db.save(updated)
        else
          say "skipping #{id}"
        end
      else
        say "creating #{id}"
        db.save(fields.merge({"_id" => id}))
      end

    end
  end
end
