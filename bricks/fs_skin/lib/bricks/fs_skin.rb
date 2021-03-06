module Bricks
  module FsSkin
    ELEM = "([a-zA-Z_]+)"
    ELEM_REGEXP = %r{^#{ELEM}$}
    SECURE_PATH_REGEXP = %r{^[a-zA-Z_/\-\+]+$}
    STATIC_SKIN_REGEXP = %r{^#{ELEM}-#{ELEM}$}
    ZAFU_URL_REGEXP    = %r{^\$#{ELEM}-#{ELEM}/(.+)$}
    BRICK_NAME_REGEXP = %r{^#{RAILS_ROOT}/bricks/#{ELEM}/zena/skins$}
    
    module ControllerMethods
      def self.included(base)
        base.alias_method_chain :get_template_text, :fs_skin
        base.alias_method_chain :template_url_for_asset, :fs_skin
        base.alias_method_chain :get_best_template, :fs_skin
      end

      def get_template_text_with_fs_skin(path, section_id = nil, opts = {})
        if path =~ ZAFU_URL_REGEXP
          brick_name, skin_name, path = $1, $2, $3
          Skin.text_from_fs_skin(brick_name, skin_name, path, opts)
        elsif !(path =~ %r{^(/|\$)}) && section_id.nil? && @fs_skin_brick_name && @fs_skin_skin_name
          Skin.text_from_fs_skin(@fs_skin_brick_name, @fs_skin_skin_name, path, opts)
        else
          return *get_template_text_without_fs_skin(path, section_id, opts)
        end
      end

      def template_url_for_asset_with_fs_skin(opts)
        # TODO
        template_url_for_asset_without_fs_skin(opts)
      end

      def get_best_template_with_fs_skin(kpaths, format, mode, skin)
        return get_best_template_without_fs_skin(kpaths, format, mode, skin) unless fs_skin = skin.z_fs_skin
        if idx_template = IdxTemplate.first(
           :conditions => ["tkpath IN (?) AND format = ? AND mode #{mode ? '=' : 'IS'} ? AND (skin_id = ? OR fs_skin = ?) AND site_id = ?",
              kpaths, format, mode, skin.id, fs_skin, skin.site_id],
            :order     => "length(tkpath) DESC, skin_id DESC"
          )
          if idx_template.path.nil?
            template = secure(Template) { Template.find(idx_template.node_id) }
            get_best_template_without_fs_skin(kpaths, format, mode, skin, template)
          elsif fs_skin =~ STATIC_SKIN_REGEXP
            @fs_skin_brick_name, @fs_skin_skin_name = $1, $2
            if idx_template.path =~ SECURE_PATH_REGEXP
              zafu_url = "$#{@fs_skin_brick_name}-#{@fs_skin_skin_name}/#{idx_template.path}"
              template = Template.new
              template.tkpath = idx_template.tkpath
              [zafu_url, template]
            end
          end
        end
      end

      # TODO
      # Asset resolution: route = /fs_skin/fs_skin-blog/img/style.css
      # ===> fs_skin brick ==> brick path
      # ===> blog/img/style.css ==> brick path/zena/skins/  blog/img/style.css
      # Cache in public directory
      # FIXME: clear_cache should erase /home/fs_skin
    end # ControllerMethods

    module SkinMethods
      def self.included(base)
        
        base.class_eval do
          property do |p|
            p.string 'z_fs_skin', :index => '.idx_string1'
          end

          safe_property 'z_fs_skin'
          validate :validate_z_fs_skin
          alias_method_chain :skin_name, :fs_skin
        end
        
        # We move this method here so that we do not need to reference
        # Bricks::FsSkin in I18n when fs_skin brick is disabled.
        def base.text_from_fs_skin(brick_name, skin_name, path, opts)
          if path =~ SECURE_PATH_REGEXP
            fullpath = "$#{brick_name}-#{skin_name}/#{path}"
            section_id = nil
            template = nil
            
            abs_path = File.join(RAILS_ROOT, 'bricks', brick_name, 'zena', 'skins', skin_name, path)
            if opts[:ext]
              abs_path_l = abs_path + ".#{visitor.lang}.#{opts[:ext]}"
              abs_path = abs_path + ".#{opts[:ext]}"
            else
              abs_path_l ||= abs_path + ".zafu"
            end
            if abs_path_l
              if text = File.exist?(abs_path_l) ? File.read(abs_path_l) : nil
                return text, fullpath, section_id, template
              end
            end
            if text = File.exist?(abs_path) ? File.read(abs_path) : nil
              return text, fullpath, section_id, template
            end
          end
        end
      end
      
      def skin_name_with_fs_skin
        z_fs_skin ? ('$' + z_fs_skin) : skin_name_without_fs_skin
      end

      private
        def validate_z_fs_skin
          if !(z_fs_skin.nil? || z_fs_skin =~ STATIC_SKIN_REGEXP)
            errors.add(:z_fs_skin, _('invalid'))
          end
          true
        end
    end # SkinMethods

    module SiteMethods
      def self.included(base)
        base.alias_method_chain :rebuild_index, :fs_skin
      end

      def rebuild_index_with_fs_skin(nodes = nil, page = nil, page_count = nil)
        if !page
          Zena::SiteWorker.perform(self, :rebuild_fs_skin_index, nil)
        end
        rebuild_index_without_fs_skin(nodes, page, page_count)
      end

      def rebuild_fs_skin_index
        Zena::Db.execute "DELETE FROM idx_templates WHERE node_id IS NULL AND site_id = #{id}"
        Bricks.paths_for('zena/skins').each do |p|
          if p =~ BRICK_NAME_REGEXP
            brick_name = $1
            list = []
            Dir.foreach(p) do |skin_name|
              if skin_name =~ ELEM_REGEXP
                build_fs_skin_index(brick_name, skin_name, "#{p}/#{skin_name}")
              end
            end
          end
        end
      end

      private
        def add_fs_skin_symlink(brick_name, skin_name, skin_path)
          source_path = File.join(skin_path, 'static')
          target_dir  = File.join(RAILS_ROOT, 'public', 'static')
          target_path = File.join(target_dir, "#{brick_name}-#{skin_name}") 
          if File.exist?(source_path) && !File.exist?(target_path)
            if !File.exist?(target_dir)
              Dir.mkdir(target_dir)
            end
            FileUtils.symlink_or_copy(source_path, target_path)
          end
        end
        
        def build_fs_skin_index(brick_name, skin_name, path)
          add_fs_skin_symlink(brick_name, skin_name, path)
          # path = absolute path
          # 1. Find all templates
          Dir.foreach(path) do |elem|
            next if elem =~ /^\./
            elem_path = File.join(path, elem)
            if File.directory?(elem_path)
              build_fs_skin_index(brick_name, skin_name, elem_path)
            elsif elem =~ Template::MODE_FORMAT_FROM_TITLE
              # 2. Get klass, mode, format
              klass    = $1
              mode     = $4.blank? ? nil : $4
              format   = $6 || 'html'
              idx_path = elem_path[%r{^#{RAILS_ROOT}/bricks/#{brick_name}/zena/skins/#{skin_name}/(.+)\.zafu$}, 1]
              # 3. Get kpath
              if idx_path && vclass = VirtualClass[klass]
                tkpath = vclass.kpath

                # 4. insert idx_template entry (kpath, site_id, mode, format, path relative to bricks/brick/zena/skins/skin_name)
                IdxTemplate.create(
                  :tkpath  => tkpath,
                  :mode    => mode,
                  :format  => format,
                  :site_id => id,
                  :fs_skin => "#{brick_name}-#{skin_name}",
                  :path    => idx_path
                )
              end
            end
          end
        end
    end # SiteMethods
  end # FsSkin
end # Bricks
