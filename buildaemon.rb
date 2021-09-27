module Buildaemon
  module Sugar
    require "fileutils"
    
    def call(command)
      puts "[#{Dir.pwd}] #{command}"
      if 0 != Command.Call(command)
        if block_given?
          abort yield
        else
          abort
        end
      end
    end
    
    def changed(path)
      if block_given?
        Dir.chdir(path){yield}
      else
        Dir.chdir(path)
      end
    end
    
    def maked(path)
      FileUtils.mkdir_p(path) if ! Dir.exists?(path)
      Dir.chdir(path){yield} if block_given?
    end
    
    def file_is_update(base_path, target_path)
      File.exists?(target_path) ? File::Stat.new(target_path).mtime < File::Stat.new(base_path).mtime : true
    end
  end
  
  class Command
    def self.Call(command)
      begin
        Process.waitpid(spawn(command))
      rescue => e
        STDERR.puts e.message
      end
      $?.exitstatus
    end
  end
  
  class Environment
    def self.Get(name)
      return ENV[name] if ENV.key?(name)
      return block_given? ? Environment.Set(name, yield) : nil
    end
    
    def self.Set(name, value)
      ENV[name] = value.instance_of?(String) ? value : value.to_s
    end
  end
  
  class Buildaemon
    include Sugar
    
    def self.Platform
      Environment.Get("BDMN_PLATFORM"){
        case RUBY_PLATFORM.downcase
        when /darwin/
          "macos"
        else
          "unknown"
        end
      }.downcase
    end
    
    def self.Configuration
      Environment.Get("BDMN_CONFIG"){"debug"}.downcase
    end
    
    def self.BuildTag(platform, configuration)
      Environment.Get("BDMN_BUILD_TAG"){
        configuration = configuration.capitalize
        case platform
        when "macos"
          "#{`xcrun --sdk macosx --show-sdk-version`.chomp}_#{configuration}"
        else
          "unknown_#{configuration}"
        end
      }
    end
    
    def self.Run(args)
      action = args.shift
      case action
      when "build"
        Buildaemon.Build
      else
        abort "Invalid action: #{action} #{args}"
      end
    end
    
    def self.Build
      extend Sugar
      
      platform = Buildaemon.Platform
      configuration = Buildaemon.Configuration
      
      require "yaml"
      buildaemon = YAML.load_file(Environment.Set("BDMN_FILE", "#{Environment.Set('BDMN_ROOT', File.expand_path('.'))}/buildaemon.yaml"))
      buildaemon_file_path = Environment.Get("BDMN_FILE")
      build_tag = Buildaemon.BuildTag(platform, configuration)
      Environment.Set("BDMN_BUILD_TAG", build_tag)
      
      maked("platforms/#{platform}/#{build_tag}"){
        buildaemon["platforms"][platform]["commands"].each{|command|
          command.each{|name, value|
            case name
            when "cmake"
              Cmake(buildaemon, buildaemon_file_path, platform, configuration)
            else
              abort "Unsupported command: #{name} #{value}"
            end
          }
        }
      }
    end
    
    def self.Cmake(buildaemon, buildaemon_file_path, platform, configuration)
      configurations = buildaemon["platforms"][platform]["configurations"]
      buildaemon["builds"].each{|build|
        maked(build["name"]){
          cmake_file_path = "./CMakeLists.txt"
          if file_is_update(buildaemon_file_path, cmake_file_path)
            open(cmake_file_path, "w"){|file|
              file.puts <<EOS
cmake_minimum_required(VERSION 2.8)
message("BDMN_ROOT: ${BDMN_ROOT}")
message("BDMN_BUILD_TAG: ${BDMN_BUILD_TAG}")
message("BDMN_ARCH: ${BDMN_ARCH}")
set(CMAKE_VERBOSE_MAKEFILE 1)
if (DEFINED CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_MACOSX_RPATH 1)
endif()
project(#{build["name"]})
include_directories(#{build["incs"].join(" ")})
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} #{configurations[configuration]['flags']['c']}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} #{configurations[configuration]['flags']['cxx']}")
set(SRCS #{build["srcs"].join(" ")})
EOS
              
              case build["type"]
              when "lib"
                file.puts <<EOS
add_library(#{build["name"]}-static STATIC ${SRCS})
SET_TARGET_PROPERTIES(#{build["name"]}-static PROPERTIES OUTPUT_NAME #{build["name"]})
add_library(#{build["name"]}-shared SHARED ${SRCS})
SET_TARGET_PROPERTIES(#{build["name"]}-shared PROPERTIES OUTPUT_NAME #{build["name"]})
EOS
              when "exe"
                file.puts <<EOS
add_executable(#{build["name"]} ${SRCS})
target_link_libraries(#{build["name"]} #{configurations[configuration]['links']})
EOS
              else
                abort "Unsupported type: #{build['type']}"
              end
            }
            
            buildaemon["platforms"][platform]["architectures"].each{|arch|
              maked(arch){
                Environment.Set("BDMN_ARCH", arch)
                options = [
                  "-DBDMN_ROOT=#{Environment.Get('BDMN_ROOT')}",
                  "-DBDMN_BUILD_TAG=#{Environment.Get('BDMN_BUILD_TAG')}",
                  "-DBDMN_ARCH=#{Environment.Get('BDMN_ARCH')}"
                ]
                case platform
                when "macos"
                  options.push "-DCMAKE_OSX_ARCHITECTURES=#{Environment.Get('BDMN_ARCH')}"
                end
                call "cmake .. #{options.join(' ')}"
              }
            }
          end
          
          buildaemon["platforms"][platform]["architectures"].each{|arch|
            changed(arch){
              call "make clean all"
            }
          }
          
          case build["type"]
          when "lib"
            case platform
            when "macos"
              call "lipo -create */*.a -output lib#{build['name']}.a"
              call "lipo -create */*.dylib -output lib#{build['name']}.dylib"
            end
          end
        }
      }
    end
  end
end

Buildaemon::Buildaemon.Run(ARGV.each{|v|}) if $0 == __FILE__
