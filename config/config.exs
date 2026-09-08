import Config

config :ash, default_string_length_count: :codepoints

# Keep this repository's tests isolated from the VM-wide Logger. Configuration
# files from dependencies are not imported into host applications.
if config_env() == :test do
  config :journal_ash, install_logger_filter: false
end
