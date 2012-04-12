require 'fileutils'
require 'fiber'

class HaskellPlugin < StagingPlugin
  # TODO - Is there a way to avoid this without some kind of 'register' callback?
  # e.g. StagingPlugin.register('sinatra', __FILE__)
  def framework
    'haskell'
  end

  def stage_application
    Dir.chdir(destination_directory) do
      create_app_directories
      copy_source_files
      cabal_build
      create_startup_script
      create_stop_script
    end
  end

  # Let DEA fill in as needed..
  def start_command
    "#{detect_main_file} $@"
  end

  private

  def startup_script
    vars = environment_hash
    generate_startup_script(vars)
  end

  def stop_script
    vars = environment_hash
    generate_stop_script(vars)
  end

  # TODO - I'm fairly sure this problem of 'no standard startup command' is
  # going to be limited to Sinatra and Node.js. If not, it probably deserves
  # a place in the sinatra.yml manifest.
  def detect_main_file
    file = app_files_matching_patterns.first
    raise 'Unable to determine Haskell startup command' unless file
    raise 'Unable to determine executable command from cabal file' unless File.read(File.join(destination_directory,'app',file)) =~ /^Executable\s+([^\s]+)$/
    "dist/build/#{$1}/#{$1}"
  end

  def cabal_build
    tmp_dir = Dir.mktmpdir

    # make the build directory and copy the source
    %x{mkdir -p #{tmp_dir}}
    %x{cp -r #{File.join(source_directory,'.')} #{tmp_dir}}

    # if in secure mode, chmod/chown it
    if @staging_uid
      chmod_output = `/bin/chmod 0755 #{tmp_dir} 2>&1`
      raise "Failed chmodding install dir: #{chmod_output}" if $?.exitstatus != 0

      chown_output = `sudo /bin/chown -R #{@staging_uid} #{tmp_dir} 2>&1`
      raise "Failed chowning install dir: #{chown_output}" if $?.exitstatus != 0
    end

    # do the building
    Bundler.with_clean_env do
      Dir.chdir(tmp_dir) do
        secure_exec("cabal install --only-dependencies --disable-shared --disable-documentation --disable-tests")
        secure_exec("cabal configure -fproduction")
        secure_exec("cabal build")
      end
    end

    # chown back
    me = `whoami`.chomp
    `sudo chown -R #{me} #{tmp_dir}`
    raise "Failed chowning #{tmp_dir} to #{me}" if $?.exitstatus != 0

    # copy the compiled binary
    %x{cp -r #{File.join(tmp_dir,'dist')} #{File.join(destination_directory,'app')}}

    # remove the build directory
    FileUtils.remove_entry_secure(tmp_dir)
  end

  def secure_exec(cmd)
    # Finally, do the install
    pid = fork
    if pid
      # Parent, wait for staging to complete
      Process.waitpid(pid)
      child_status = $?

      # Kill any stray processes that the compilation may have created
      if @staging_uid
        `sudo -u '##{@staging_uid}' pkill -9 -U #{@staging_uid} 2>&1`
      end

      if child_status.exitstatus != 0
        raise "Failed executing #{cmd}"
      end
    else
      close_fds
      File.umask(0002)
      exec("env HOME=/usr/local/haskell sudo -u '##{@staging_uid}' #{cmd}")
    end
  end

  def close_fds
    3.upto(get_max_open_fd) do |fd|
      begin
        IO.for_fd(fd, "r").close
      rescue
      end
    end
  end

  def get_max_open_fd
    max = 0

    dir = nil
    if File.directory?("/proc/self/fd/") # Linux
      dir = "/proc/self/fd/"
    elsif File.directory?("/dev/fd/") # Mac
      dir = "/dev/fd/"
    end

    if dir
      Dir.foreach(dir) do |entry|
        begin
          pid = Integer(entry)
          max = pid if pid > max
        rescue
        end
      end
    else
      max = 65535
    end

    max
  end
end
