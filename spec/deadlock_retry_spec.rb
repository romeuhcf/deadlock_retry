require "rubygems"
4
# Change the version if you want to test a different version of ActiveRecord
gem "activerecord", ENV["ACTIVERECORD_VERSION"] || "~>5.2"
require "active_record"
require "active_record/version"
puts "Testing ActiveRecord #{ActiveRecord::VERSION::STRING}"

require "logger"
require "deadlock_retry"

class MockModel
  @@open_transactions = 0

  def self.transaction(*objects)
    @@open_transactions += 1
    yield
  ensure
    @@open_transactions -= 1
  end

  def self.open_transactions
    @@open_transactions
  end

  def self.connection
    self
  end

  def self.logger
    @logger ||= Logger.new(nil)
  end

  def self.show_innodb_status
    []
  end

  def self.select_rows(sql)
    [["version", "5.1.45"]]
  end

  def self.select_value(sql)
    true
  end

  def self.adapter_name
    "MySQL"
  end

  include DeadlockRetry
end

RSpec.describe DeadlockRetry do
  DEADLOCK_ERROR = "MySQL::Error: Deadlock found when trying to get lock"
  TIMEOUT_ERROR = "MySQL::Error: Lock wait timeout exceeded"

  describe "base" do
    it "is included_by_default" do
      expect(ActiveRecord::Base.method(:transaction).source_location.first).to include("deadlock_retry")
      expect(ActiveRecord::Base.method(:exponential_pause).source_location.first).to include("deadlock_retry")
    end
  end

  describe "on a model" do
    it "handles no_errors" do
      expect(MockModel.transaction { :success }).to eq :success
    end

    it "handles no_errors_with_deadlock" do
      errors = [DEADLOCK_ERROR] * 3
      expect(MockModel.transaction { raise ActiveRecord::StatementInvalid, errors.shift unless errors.empty?; :success }).to eq :success
      expect(errors).to be_empty
    end

    it "handles no_errors_with_lock_timeout" do
      errors = [TIMEOUT_ERROR] * 3
      expect(MockModel.transaction { raise ActiveRecord::StatementInvalid, errors.shift unless errors.empty?; :success }).to eq :success
      expect(errors).to be_empty
    end

    it "handles error_if_limit_exceeded" do
      expect do
        MockModel.transaction { raise ActiveRecord::StatementInvalid, DEADLOCK_ERROR }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "handles error_if_unrecognized_error" do
      expect do
        MockModel.transaction { raise ActiveRecord::StatementInvalid, "Something else" }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "handles innodb_status_availability" do
      DeadlockRetry.innodb_status_cmd = nil
      MockModel.transaction { }
      expect(DeadlockRetry.innodb_status_cmd).to eq "show innodb status"
    end

    it "handles error_in_nested_transaction_should_retry_outermost_transaction" do
      tries = 0
      errors = 0

      MockModel.transaction do
        tries += 1
        MockModel.transaction do
          MockModel.transaction do
            errors += 1
            raise ActiveRecord::StatementInvalid, "MySQL::Error: Lock wait timeout exceeded" unless errors > 3
          end
        end
      end

      expect(tries).to be 4
    end
  end
end
