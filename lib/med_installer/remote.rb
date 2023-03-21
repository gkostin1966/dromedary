require "hanami/cli"
require "annoying_utilities"
require_relative "logger"

module MedInstaller
  class Remote
    extend MedInstaller::Logger

    VALID_TARGETS = %w[testing staging production]
    PANIC_PAUSE = 5

    def self.valid_target?(t)
      target = t.downcase
      VALID_TARGETS.include? target
    end

    def self.validate_target!(t)
      if valid_target?(t)
        t.downcase
      else
        raise "Target must be one of [#{VALID_TARGETS.join(", ")}]"
      end
    end

    def self.remote_exec(target, cmd)
      logger.info "Telling #{target} to run #{cmd}"
      # full_command = "ssh deployhost exec -v --env=RAILS_ENV:production dromedary-#{target} app ruby #{cmd}"
      full_command = %(ssh deployhost exec dromedary-#{target} "#{cmd}")
      system full_command
    end

    class Deploy < Hanami::CLI::Command
      include MedInstaller::Logger

      desc "Deploy to a valid target (testing/staging/production)"
      argument :target, required: true, desc: "Which deployment (testing/staging/production)"
      argument :branch, default: "master", desc: "Which branch/tag/SHA to deploy"

      def call(target:, branch:)
        target = Remote.validate_target!(target)
        logger.info "Deploying #{branch} to #{target.upcase}"
        sleep(Remote::PANIC_PAUSE)
        cmd = "ssh deployhost deploy dromedary-#{target} #{branch}"
        logger.info cmd
        system cmd
      end
    end

    class Restart < Hanami::CLI::Command
      include MedInstaller::Logger

      desc "Restart the puma server for a valid target"
      argument :target, required: true, desc: "Which deployment (testing/staging/production)"

      def call(target:)
        target = Remote.validate_target!(target)
        logger.info "Restarting puma server for #{target.upcase}"
        system "ssh deployhost restart dromedary-#{target}"
      end
    end

    class Dromedary < Hanami::CLI::Command
      include MedInstaller::Logger

      desc "Run a bin/dromedary command on a remote server"
      argument :target, required: true, desc: "Which deployment (testing/staging/production)"
      argument :command, required: true, desc: "The command to run (e.g., \"solr reload\" IN DOUBLE QUOTES)"
      argument :arg1, required: false, default: ""
      argument :arg2, required: false, default: ""
      argument :arg3, required: false, default: ""

      def call(target:, command:, arg1:, arg2:, arg3:)
        target = Remote.validate_target!(target)
        sleep(Remote::PANIC_PAUSE)
        cmd = %(bin/dromedary #{[command, arg1, arg2, arg3].join(" ").strip})
        Remote.remote_exec(target, cmd)
      end
    end

    class Exec < Hanami::CLI::Command
      include MedInstaller::Logger

      desc "Run an arbitrary command using deploy exec"
      argument :target, required: true, desc: "Which deployment (testing/staging/production)"
      argument :command, required: true, desc: "The command to run (e.g., \"curl http://localhost...\" IN DOUBLE QUOTES)"

      def call(target:, command:)
        target = Remote.validate_target!(target)
        sleep(Remote::PANIC_PAUSE)
        Remote.remote_exec(target, command)
      end
    end
  end
end
