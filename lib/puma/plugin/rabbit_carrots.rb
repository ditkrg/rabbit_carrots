# rabbit_carrots.rb
require 'English'
require 'puma/plugin'
require 'rabbit_carrots'

Puma::Plugin.create do
  attr_reader :puma_pid, :rabbit_carrots_pid, :log_writer, :core_service

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $PROCESS_ID

    @core_service = RabbitCarrots::Core.new(logger: log_writer)

    in_background do
      monitor_rabbit_carrots
    end

    launcher.events.on_booted do
      @rabbit_carrots_pid = fork do
        Thread.new { monitor_puma }
        start_rabbit_carrots_consumer
      end
    end

    launcher.events.on_stopped { stop_rabbit_carrots }
    launcher.events.on_restart { stop_rabbit_carrots }
  end

  private

  def start_rabbit_carrots_consumer
    core_service.start(kill_to_restart_on_standard_error: true)
  rescue StandardError => e
    Rails.logger.error "Error starting Rabbit Carrots: #{e.message}"
  end

  def stop_rabbit_carrots
    return unless rabbit_carrots_pid

    log 'Stopping Rabbit Carrots...'
    core_service.request_shutdown
    Process.kill('TERM', rabbit_carrots_pid)
    Process.wait(rabbit_carrots_pid)
  rescue Errno::ECHILD, Errno::ESRCH
    log 'Rabbit Carrots already stopped'
  end

  def monitor_puma
    monitor(:puma_dead?, 'Detected Puma has gone away, stopping Rabbit Carrots...')
  end

  def monitor_rabbit_carrots
    monitor(:rabbit_carrots_dead?, 'Rabbits Carrot is dead, stopping Puma...')
  end

  def monitor(process_dead, message)
    loop do
      if send(process_dead)
        log message
        Process.kill('TERM', $PROCESS_ID)
        break
      end
      sleep 2
    end
  end

  def rabbit_carrots_dead?
    Process.waitpid(rabbit_carrots_pid, Process::WNOHANG) if rabbit_carrots_started?
    false
  rescue Errno::ECHILD, Errno::ESRCH
    true
  end

  def rabbit_carrots_started?
    rabbit_carrots_pid.present?
  end

  def puma_dead?
    Process.ppid != puma_pid
  end

  def log(...)
    log_writer.log(...)
  end
end
