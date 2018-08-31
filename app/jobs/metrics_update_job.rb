# frozen_string_literal: true

class MetricsUpdateJob < ApplicationJob
  queue_as :default

  def perform(path, db_runtime)
    number_of_the_day = SecureRandom.base64
    # return if ENV['DISABLE_QUERY_LOGGER']
    @logger ||= Logger.new(File.join(Rails.root, 'log', 'metrics_update_job_errors.log'))
    puts 'Is sesnsible routes timing out?'
    route = Rails.sensible_routes.match_for path
    puts "#{number_of_the_day} Checkpoint 1"
    return if route.nil?
    normalized_path = "#{route.verb} #{route.path}"
    puts "#{number_of_the_day} Checkpoint 2"
    Rails.logger.info "#{normalized_path} #{db_runtime}"

    query = QueryAverage.find_or_create_by(path: normalized_path)
    puts "#{number_of_the_day} Checkpoint 3"
    Rails.logger.info "BEFORE: #{query.counter} #{query.average}"
    query.average = (query.average * query.counter + db_runtime) / (query.counter += 1)
    puts "#{number_of_the_day} Checkpoint 4"
    # https://stackoverflow.com/questions/24270994/sudden-inexplicable-active-record-connection-timeouts-while-testing-with-rspec
    Rails.application.executor.wrap do
      query.save
    end
    puts "#{number_of_the_day} Checkpoint 5"
    Rails.logger.info "AFTER: #{query.counter} #{query.average}"
    puts 'Exited! (no error)'
  rescue => e
    puts e.message
    puts e.backtrace
    @logger.error e.message
    e.backtrace.each { |line| @logger.error line }
    puts 'Exited! (error)'
  end
end
