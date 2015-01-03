#!/usr/bin/env ruby
#
require 'mysql2'
require 'active_support/inflector'

require 'flapjack/redis_proxy'
require 'flapjack/record_queue'
require 'flapjack/utility'
require 'flapjack/exceptions'

require 'flapjack/data/alert'
require 'flapjack/data/check'

module Flapjack
  module Gateways
    class SmsGammu

      attr_accessor :sent

      include Flapjack::Utility

      def initialize(opts = {})

        @lock = opts[:lock]

        @config = opts[:config]

        # TODO support for config reloading
        @queue = Flapjack::RecordQueue.new(@config['queue'] || 'sms_gammu_notifications',
                   Flapjack::Data::Alert)

        @mysql_client = Mysql2::Client.new(host: 'localhost', 
                                           username: @config[:mysql_username],
                                           password: @config[:mysql_password])

        @sent = 0

        Flapjack.logger.debug("new sms_gammu gateway pikelet with the following options: #{@config.inspect}")
      end

      def start
        begin
          Sandstorm.redis = Flapjack.redis

          loop do
            @lock.synchronize do
              @queue.foreach {|alert| handle_alert(alert) }
            end

            @queue.wait
          end
        ensure
          Flapjack.redis.quit
        end
      end

      def stop_type
        :exception
      end

      private

      def handle_alert(alert)
        account_sid = @config["account_sid"]
        auth_token = @config["auth_token"]
        from = @config["from"]

        address = alert.medium.address
        notification_id = alert.id
        message_type = alert.rollup ? 'rollup' : 'alert'

        ###
        # Render message template
        ###
        @alert = alert
        bnd = binding

        sms_dir = File.join(File.dirname(__FILE__), 'sms_gammu')

        sms_template_path = case
        when @config.has_key?('templates') && @config['templates']["#{message_type}.text"]
          @config['templates']["#{message_type}.text"]
        else
          File.join(sms_dir, "#{message_type}.text.erb")
        end
        sms_template = ERB.new(File.read(sms_template_path), nil, '-')

        @alert = alert
        bnd = binding

        begin
          message = sms_template.result(bnd).chomp
        rescue => e
          Flapjack.logger.error "Error while executing the ERB for an sms: " +
            "ERB being executed: #{sms_template_path}"
          raise
        end


        if @config.nil? || (@config.respond_to?(:empty?) && @config.empty?)
          Flapjack.logger.error "sms_gammu config is missing"
          return
        end

        errors = []

        [[mysql_username, "Gammu mysql username is missing"],
         [mysql_password, "Gammu mysql password is missing"],
         [from, "SMS from address is missing"],
         [address, "SMS address is missing"],
         [notification_id, "Notification id is missing"]].each do |val_err|

          next unless val_err.first.nil? || (val_err.first.respond_to?(:empty?) && val_err.first.empty?)
          errors << val_err.last
        end

        unless errors.empty?
          errors.each {|err| Flapjack.logger.error err }
          return
        end

        body_data = {
          'To'   => address,
          'From' => from,
          'Body' => truncate(message, 159),
        }

        Flapjack.logger.debug "body_data: #{body_data.inspect}"
        Flapjack.logger.debug "authorization: [#{account_sid}, #{auth_token[0..2]}...#{auth_token[-3..-1]}]"

        result = @mysql_client.query("INSERT INTO outbox (CreatorID, SenderID, DeliveryReport, MultiPart,
                                                 InsertIntoDB, Text, DestinationNumber, RelativeValidity, Coding, UDH, Class,
                                                 sTextDecoded) VALUES (#{from}, 11111111, #{true}, #{false}, #{Time.now}, #{message}, #{to}, '', '', '', '', '')")


        Flapjack.logger.debug "Gammu server response: #{result}"

      rescue => e
        Flapjack.logger.error "Error generating or delivering gammu sms to #{alert.medium.address}: #{e.class}: #{e.message}"
        Flapjack.logger.error e.backtrace.join("\n")
        raise
      end

    end
  end
end

