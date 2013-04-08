require 'rubygems'
require 'sinatra'
require 'twilio-ruby'
require 'sequel'
require 'json'
require 'pony'
require 'haml'
require 'rest-client'
require 'date'
require 'csv'
require "faster_csv"
CSV = FCSV # since csv doesn't seem to work well with Ruby < 1.9
load 'key_parameters.rb' # this brings in the key parameters and other sensitive/changeable information

#tell sequel to treat times as UTC
Sequel.default_timezone = :utc
#DB.fetch("SET time_zone='+00:00'").first

$client = Twilio::REST::Client.new $sid, $token

## some helper functions

# to protect pages
# just need to put !protect at the begining
helpers do

  def protected!
    unless authorized?
      response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
      throw(:halt, [401, "Not authorized\n"])
    end
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [$protected_user, $protected_password]
  end
end

# helper for some of the gui html stuff
class Array
  def to_cells(tag)
    self.map { |c| "<#{tag}>#{c}</#{tag}>" }.join
  end
end

# takes a number with or without '+' and adds a '+' if it isn't there
# in some cases sinatra removes the '+'
def standardize_number(num)
  #for testing we will accept +1 numbers
  if num.grep(/^\+*\s*1/).length == 1
    num = num.gsub(/^\+/,'')
    num =  "+" + num
  else
    num = num.gsub(/^\+/,'')
    num = num.gsub(/^\s*88/,'')
    num = "+88" + num
  end
  num.gsub(/\s+/,'')
end

def send_email(to,subject,body)
  stack = `tail -100 logs/sinatra.log`
  RestClient.post $mailgun_apikey +
  "@api.mailgun.net/v2/bangpharma.mailgun.org/messages",
  :from => $sender_email_address,
  :to => to,
  :subject => subject,
  :text => "#{body} \n #{"_" *20} \n  #{stack}"
end

def send_try_again_sms(to,additional_message='')
  $client.account.sms.messages.create(
                                      :from => $sms_out_number,
                                      :to => to,
                                      :body => "Error: Sorry the system did not understand your request." + additional_message)
  nil
end

# makes entries to db for field registration
def field_register_pharmacy(pharm_number,pharm_contact_name,staff_phone_number)
  pharm_number = standardize_number(pharm_number[0])

  #check to make sure this number is not already registered
  phone_number_in_db = Number.where(:id => pharm_number)
  if phone_number_in_db.count > 0
    send_try_again_sms(staff_phone_number,"This number is already registered to pharmacy #{phone_number_in_db.first.pharmacy_id}")
    return nil
  end


  Pharmacy.insert(:preferred_number_id => pharm_number,
                  :name => pharm_contact_name)
  pid = Pharmacy.where(:preferred_number_id => pharm_number).first.id

  Number.insert(
                :id => pharm_number,
                :pharmacy_id => pid,
                :call_this_number => 1,
                :created_at => Time.now
                )

  #settings so we dont call em
  PendingCall.insert(
                     :number_id => pharm_number,
                     :attempts => $max_ors_attempts,
                     :error_message_sent => 1
                     )

  # Default start and end time for pharmacies
  AvailableTime.insert(
                       :pharmacy_id => pid,
                       :start_time => "09:00:00",
                       :end_time => "21:00:00"
                       )

  sms_message_confirmation = "Registration successful. Pharmacy ID number is #{pid}"
  $stderr.puts "sending reg confirmation to  to #{staff_phone_number}"

  $client.account.sms.messages.create(
                                      :from => $sms_out_number,
                                      :to => staff_phone_number,
                                      :body => sms_message_confirmation)
  #send message to user
  $stderr.puts "sending reg confirmation to  to #{pharm_number}"
  $client.account.sms.messages.create(
                                      :from => $sms_out_number,
                                      :to => pharm_number,
                                      :body => "Welcome to bangpharma. Your pharmacy ID is #{pid}.")

  return nil
end

# turns pharmacy numbers on and off as long as it is not the primary one
def turn_number(pharm_number,off_or_on,staff_phone_number)
  $stderr.puts "trying to turn number #{off_or_on}"
  # does not allow anyone to turn off a primary number
  is_primary_number  = Pharmacy.where(:preferred_number_id => pharm_number).count > 0

  if (is_primary_number)
    sms_message = "Sorry this is the primary number associated with this pharmacy. If this number needs to be turned off, please contact Satter."
    $client.account.sms.messages.create(
                                        :from => $sms_out_number,
                                        :to => staff_phone_number,
                                        :body => sms_message)

    else

    #TO DO : we may have this number lingerieng hte in the pending calls table so probably want to check and remove

    Number.where(:id => pharm_number).first.update(:call_this_number => off_or_on == 'on' ? 1 : 0)
    sms_message_confirmation = "#{pharm_number} has been turned #{off_or_on}. Thank you."
    $client.account.sms.messages.create(
                                        :from => $sms_out_number,
                                        :to => staff_phone_number,
                                        :body => sms_message_confirmation)
  end
  nil
end

def delete_pharmacy(message,sms_number)
  chopped_message = message.gsub(/^delete\s*pharm\s/i,'').split("\s")
  return send_try_again_sms(sms_number) if chopped_message.length != 1
  rem_pid = chopped_message[0]
  $stderr.puts "trying to remove pharmacy #{rem_pid}"
  pharmacy = Pharmacy.where(:id => rem_pid)

  #check that pharmacy exisits
  return send_try_again_sms(sms_number,' Pharmacy does not exist') if pharmacy.count != 1
  #delete pharmacy
  pharmacy.first.pending_call.delete
  Number.where(:pharmacy_id => rem_pid).delete
  pharmacy.first.delete
  $client.account.sms.messages.create(
                                      :from => $sms_out_number,
                                      :to => sms_number,
                                      :body => "Pharmacy #{rem_pid} has been removed.")
  return nil
end

#used for sms registering of number
def register_number(message,sms_number)
  chopped_message = message.gsub(/^\s*reg\s/i,'').split("\s")
  $stderr.puts chopped_message
  # check that it is length 2
  send_try_again_sms(sms_number) if chopped_message.length != 2
  register_number = chopped_message.grep(/\d+/)
  #TODO - could make this more robust and allow for +88 too
  if register_number[0].length != 11 and register_number.grep(/^\+1/).length != 1 #length of phone numbers in bangladesh
    send_try_again_sms(sms_number,
                       " The phone number should be 11 digits long")
    return nil
  end

  register_name = chopped_message.grep(/[a-zA-Z]+/)

  if register_name.length == 1 and register_number.length == 1
    $stderr.puts "meets field register reqs"
    field_register_pharmacy(register_number,register_name,sms_number)
  else
    send_try_again_sms(sms_number)
  end
  return nil
end

def remove_number(message,sms_number)
  chopped_message = message.gsub(/^remove\s/i,'').split("\s")
  return send_try_again_sms(sms_number) if chopped_message.length != 1
  remove_number = standardize_number(chopped_message[0])
  $stderr.puts "trying to remove #{remove_number}"
  # look in database
  if Pharmacy.where(:preferred_number_id => remove_number).count > 0
    send_try_again_sms(sms_number,"We cannot remove the primary number.")
  elsif Number.where(:id => remove_number).count > 0
    Number.where(:id => remove_number).first.delete
    #send message
    $client.account.sms.messages.create(:from => $sms_out_number,
                                        :to => sms_number,
                                        :body => "#{remove_number} has been removed from bangpharma.")
    else
    send_try_again_sms(sms_number, "Cannot delete number form system.")
  end
  nil
end

#function that is hit when sms with special code is sent indiciating daily test
def confirm_daily_test_sms()
  Test.order(:created_at).last.update(:incoming_sms => 1)
end


## Defining sequel classes and methods
class PendingCall<Sequel::Model
  many_to_one :number
  def pharmacy
    number.pharmacy if number
  end
end

class AvailableTime < Sequel::Model
  many_to_one :pharmacy
end

class SmsMessage < Sequel::Model
#TO DO:  may want to add some stuff here
end

class Sale < Sequel::Model
  many_to_one :number
  def pharmacy
    number.pharmacy if number
  end

end

class Pharmacy < Sequel::Model
  one_to_many :numbers

  # determines if call is required and updates pending calls table
  def requires_call(max_lag,max_attempts)
    # now find the correct entry in pending_calls
    call = self.pending_call
    if (self.is_late(max_lag))
      puts "pharmacy #{self.id} is late"
      if (call.attempts.to_i < max_attempts.to_i)
        puts "#{call.attempts} attempts left out of #{max_attempts}"
        if (self.is_acceptable_call_time)
          #note that is_acceptable call time acutally will update attemps if it is an acceptable time
          puts "acceptable call time"
          call.update(:number_id => self.get_next_number(call.number_id))
          ## if we are on the last number then update attempts
          if (self.is_last_available_number(call.number_id))
            puts "last available number"
            call.update(:attempts => call.attempts + 1)
          end

          return true
        end
        ## if attempts are greater than max attemps then
      else
        ## alert admins if we haven't already done so
        unless call.error_message_sent
          puts call.error_message_sent
          puts "issuing error"
          error_message = "Pharmacy (pid:#{self.id}) could not be reached"

          Error.report({
                         :number_id => self.preferred_number_id,
                         :message => error_message,
                         :code => 2,
                         :created_at => Time.now
                       })

          call.update(:error_message_sent => 1)
        end
      end
    end
    return false
  end

  # note that sales will report all sale attempts not just those that have outcome == 1
  def sales
    Sale.filter(:pharmacy_id => self.id)
  end

  def last_sale
    # getting the most recent time of a sucsessful sale (filling in 1970 for unsucsessfiul ones)
    self.sales.map{ |sale|  sale.outcome == 1 ? sale.created_at : Time.mktime(1970) }.max()
  end

  def calls
    Call.filter(:phone_number => self.numbers.map do |number|
                  number.id
                end
                )
  end

  def last_call
    self.calls.map{ |call| call.created_at}.max()
  end

  def available_numbers
    self.numbers.map{|n|
      if  n.call_this_number == true
        n.id
      else
        nil
      end
    }.compact
  end

  def get_next_number(number)
    current_number_index= self.available_numbers.index(number).to_i
    if (current_number_index < (self.available_numbers.length.to_i - 1))
      return self.available_numbers[current_number_index +1]
    else
      return self.available_numbers[0]
    end
  end

  # returns true if we have a sucscessful data greater than the max_lag (in hours)
  def is_late(max_lag)
    if self.last_sale.nil?
      return false
    else
      Time.now - self.last_sale > max_lag.to_f*60*60
    end
  end

  ## gets the entry from pending calls corresponding to this pharmacy
  def pending_call
    pending_call_id = PendingCall.all.index{|pc| pc.pharmacy.id == self.id}
    if pending_call_id.nil?
      return nil
    else
      PendingCall.all[pending_call_id]
    end
end

  #returns true if this is the last number in the array of available numbers for this pharmacy
  def is_last_available_number(number)
    number_index = self.available_numbers.index{|n| n == number}
    true if number_index.to_i == (self.available_numbers.length.to_i - 1)
  end

  # gets time range of open times for a phamacy
  #note that the times here look like they have a time zone attached when looked at trhoguh sequel but they should just be treated as times (in bangladesh times zone)
  def get_acceptable_call_times
    AvailableTime.all.map{|m|
      if m.pharmacy_id == self.id #should be interger already but casting just in case
        {"start" => m.start_time.strftime("%H:%M:%S"), "stop" =>  m.end_time.strftime("%H:%M:%S")}
      else
        nil
      end
    }.compact
  end

  def is_acceptable_call_time
    current_bangladesh_time = Time.now.utc + 6*3600
    my_call_times = self.get_acceptable_call_times
    in_outs = my_call_times.map{ |time|
      (time["start"]...time["stop"]).include?(current_bangladesh_time.strftime("%H:%M:%S"))
    }
    in_outs.any?{|time| time == true}
  end

  def get_my_numbers
    num_array = Number.map{|num| num.id if num.pharmacy_id == self.id}.compact
  end
  # set call attempts to zero and reset call number
  def reset_pending_calls
    # get numbers associated with pharmacy
    my_numbers = self.get_my_numbers
    pending_index = PendingCall.map{|p| p.id if my_numbers.include? p.number_id}.compact
    prim_num = self.preferred_number_id
    PendingCall[pending_index].update(:attempts => 0, :number_id => prim_num,:error_message_sent => 0)
  end

end


class Number < Sequel::Model
  many_to_one :pharmacy
  many_to_one :pending_call
  one_to_many :calls
end

class Call < Sequel::Model
  many_to_one :number
  def update_call_status(num,status)
    time_of_last_call =  self.where(:number_id => num).max(:created_at)
    self.where(:number_id => num, :created_at => time_of_last_call).update(:outcome => status)
  end
end

class Error < Sequel::Model
  many_to_one :number
  def pharmacy
    number.pharmacy if number
  end

  # options structure:
  # hash :message, :code, :number_id,
  def self.report(options)
    Error.create(options)
    #send an sms
    pharm = Number.filter(:id => options[:number_id])
    pharm = pharm.first.pharmacy_id unless pharm.count == 0
    puts pharm
    detailed_message = "Error: #{options[:message]}, Number: #{options[:number_id]}, Pharmacy: #{pharm}"

    # send an sms to the relavant study staff
    # no need to alert everyone everytime
    $pharm_assignments.each do |name,pharms|
      if pharms.include?pharm
        num = $study_staff_numbers[name]
        $client.account.sms.messages.create(:from => $sms_out_number,
                                            :to => num,
                                            :body => detailed_message)
      end
    end

    # send an email out to admins
    $admin_emails.each do |email|
      send_email(email,
                 'Bangpharma Error',
                 detailed_message)
    end
  end
end

class Test < Sequel::Model
  nil
end


# this assumes that we pass an incoming call number to it
# will also want to pass type to it later
get '/make_call/:incoming_number/:call_type' do |incoming_number,call_type|
  $stderr.puts "making call to #{incoming_number}"
  # if number doesn't have a + before it, add one
  incoming_number = standardize_number(incoming_number)
  $stderr.puts "making call to #{incoming_number}"
  number =  Number.where(:id => incoming_number).first
  $stderr.puts number
  # log call
  Call.insert(
              :created_at => Time.now,
              :phone_number => incoming_number,
              :call_type => call_type,
              :report_type => 1,
              :outcome => 0
              )

  if number.nil?
    url = "#{$base_url}/ask_pid_number"
  else
    url = "#{$base_url}/get_sales_data_type"
  end

  $client.account.calls.create(
                               :from => $caller_id_number,
                               :to => incoming_number,
                               :url => url,
                               :fallback_url => "#{$base_url}/fallback"
                              )


end

post '/ask_pid_number' do
  Twilio::TwiML::Response.new do |r|
    r.Pause :length => 2
    r.Gather :action => "#{$base_url}/verify_pid" , :numDigits => 4, :finishOnKey => '#',:timeout => 15  do |r|
      r.Play "#{$base_url}/phone_number_not_in_system_#{$recording_language}.mp3"
      # r.Say 'We do not recognize this number in our system. Please enter your pharmacy identification number followed by a pound sign.'
    end
  end.text
end

#verify if pharmacy id is correct
post '/verify_pid' do
  pid_num = params['Digits']
  Twilio::TwiML::Response.new do |r|
    match_pharms = Pharmacy.filter(:id => pid_num)
    if (match_pharms.count == 0)
      ## ask again if we
      r.Play "#{$base_url}/not_a_valid_pid_#{$recording_language}.mp3"
      # r.Say "This is not a valid pharmacy I.D. number. We will ask you to enter it again but if you continue to experience problems, please call us at 888-4357. "
      r.Redirect "#{$base_url}/ask_pid_number"
    else
      r.Gather :action => "#{$base_url}/add_new_number/pid/#{pid_num}" , :numDigits => 4, :finishOnKey => '#',:timeout => 15  do |r|
        r.Play "#{$base_url}/associate_phone_number_#{$recording_language}.mp3"
        # r.Say 'Would you like this number to be associated with our system so you do not have to enter it in the future. If yes, press 1 then pound, if no press 2 then  pound.'
      end
    end
  end.text
end

post '/add_new_number/pid/:pid' do |pid|
  $stderr.puts "adding number #{params['To']} to db"
  if params['Digits'] == '1'
    delete_me = 0
  else
    delete_me = 1
  end

  # add entry to database
  Number.insert(:id => params['To'],
                :pharmacy_id => pid,
                :call_this_number => 1-delete_me,
                :created_at => Time.now,
                :delete_me => delete_me)

  Twilio::TwiML::Response.new do |r|
    r.Redirect "#{$base_url}/get_sales_data_type"
  end.text
end


post '/get_sales_data_type' do
  # this is the hub for deciding (based on past sales)
  # what type of sales data this may be and whether we need to
  pid = Number.where(:id => params['To']).first.pharmacy_id
  pharm = Pharmacy.where(:id => pid).first

  # ask another question about the timing
  # get the time of the last sale
  current_time = Time.now.utc
  last_sale_time = pharm.last_sale

  if last_sale_time.nil? #dealing with the case where there are no previous sales
    over_reporting = false
    under_reporting = false
  else
    last_sale_time = last_sale_time.utc
    sale_in_last_n_hours = (current_time - $max_hours_since_last_sale*3600) < last_sale_time
    # same as since 6 UTC time
    noon_today = Time.utc(current_time.year,current_time.month,current_time.day,6)
    noon_yesterday = Time.utc(current_time.year,current_time.month,current_time.day,6) - 24*3600

    correct_noon = noon_today > current_time ? noon_yesterday : noon_today
    $stderr.puts "correct noon"
    $stderr.puts  correct_noon
    sale_since_last_noon = last_sale_time > correct_noon
    over_reporting = sale_in_last_n_hours || sale_since_last_noon
    under_reporting = current_time - last_sale_time > $trigger_hours_for_multiday_report_question * 3600
  end

  if over_reporting
    $stderr.puts "over reporting"
    Twilio::TwiML::Response.new do |r|
      r.Pause :length => 1
      r.Gather :action => "#{$base_url}/record_sales_report_type/type/over_report" , :numDigits => 2, :finishOnKey => '#',:timeout => 10  do |r|
        r.Play "#{$base_url}/revise_or_new_report_#{$recording_language}.mp3"
        #         r.Say 'We have received a call from your pharmacy recently. If you are calling to change the number of ORS customers you last reported
        # press 1. If you are calling to report new ORS sales press 2.'
      end
    end.text
  elsif under_reporting
    $stderr.puts "under reporting"

      Twilio::TwiML::Response.new do |r|
      r.Pause :length => 1
      r.Gather :action => "#{$base_url}/record_sales_report_type/type/under_report" , :numDigits => 2, :finishOnKey => '#',:timeout => 10  do |r|
        r.Play "#{$base_url}/single_or_multiple_day_sales_#{$recording_language}.mp3"
        # r.Say 'If you are reporting for sales from only one day press 1 and press 2 if you are reporting sales since the last call made to our system from your pharmacy.'
      end
    end.text
  else
    $stderr.puts "normal reporting"
    Twilio::TwiML::Response.new do |r|
      r.Redirect "#{$base_url}/record_sales_report_type/type/normal_report"
    end.text
  end
end

# records sales type (in the case where they are over or under reporting)
post '/record_sales_report_type/type/:type' do |type|
  if (type == "over_report")
    report_type = params['Digits'] == '2' ? 1 : 2
    $stderr.puts "over report type =" + report_type.to_s
  elsif (type == "under_report")
    report_type = params['Digits'] == '2' ? 1 : 3
    $stderr.puts "under report type =" + report_type.to_s
  else
    report_type = 1
  end

  # create sale
  pid = Number.where(:id => params['To']).first.pharmacy_id
  Sale.insert(
              :twillio_sid => params['CallSid'],
              :number_id => params['To'],
              :pharmacy_id => pid,
              :report_type => report_type,
              :outcome => 0,
              :created_at => Time.now
              )

  Twilio::TwiML::Response.new do |r|
    r.Redirect "#{$base_url}/how_many_ors"
  end.text
end

post '/how_many_ors' do
  $stderr.puts params
  $stderr.puts params['To']
  Twilio::TwiML::Response.new do |r|
    r.Gather :action => "#{$base_url}/verify_ors" , :numDigits => 3, :finishOnKey => '#',:timeout => 5  do |r|
      r.Play "#{$base_url}/how_many_ors_#{$recording_language}.mp3"
    end
    r.Redirect "#{$base_url}/how_many_ors"
  end.text
end

# this is an alternate loop to deal with times where someone cannot enter data
post '/how_many_ors_alt/attempts/:attempts' do |attempts|
  attempts = attempts.to_i
  Twilio::TwiML::Response.new do |r|
    r.Gather :action => "#{$base_url}/verify_ors" , :numDigits => 3, :finishOnKey => '#',:timeout => 10 do |r|
      r.Play "#{$base_url}/how_many_ors_#{$recording_language}.mp3"
    end
    ## this is only excecuted if Gather fails
    if (attempts > $max_ors_attempts)
      r.Play "#{$base_url}/problem_with_system_#{$recording_language}.mp3"
      # r.Say "We are sorry, there is a problem with the system.  If you try again later and this is not resolved please call 888-999-2210 for assistance. Thank you."
      error_message = "Could not enter ORS data"
      Error.report({
                     :number_id => params['To'],
                     :message => error_message,
                     :code => 1,
                     :created_at => Time.now
                   })

      r.Hangup

    else
      attempts += 1
      r.Redirect "#{$base_url}/how_many_ors_alt/attempts/#{attempts}"
    end
  end.text
end

post '/verify_ors' do
  $stderr.puts params
  ors_number = params["Digits"].to_i

  Twilio::TwiML::Response.new do |r|
    r.Gather :action => "#{$base_url}/ors_verified/ors/#{ors_number}" , :numDigits => 2, :finishOnKey => '#', :timeout => 10 do |r|
      if ors_number <= 60
        r.Play "ors_#{ors_number}_#{$recording_language}.mp3"
        r.Play "press_one_correct_two_incorrect_#{$recording_language}.mp3"
      else
        r.Say "You reported that #{ors_number} customers purchased ORS today. Press one if this is correct and two if it is incorrect"
      end
    end
    #only accepted if Gather fails
    r.Redirect "#{$base_url}/how_many_ors"
  end.text
end

post '/ors_verified/ors/:ors_number' do |ors_number|
  number_correct = params['Digits']
  Twilio::TwiML::Response.new do |r|
    if number_correct == '1'
      r.Redirect "#{$base_url}/process_data/ors/#{ors_number}"
    elsif number_correct == '2'
      r.Redirect "#{$base_url}/how_many_ors"
    else
      r.Redirect "#{$base_url}/how_many_ors"
    end
  end.text
end

post '/process_data/ors/:ors_number' do |ors_number|

  # update the sale that was started with report type
  Sale.where(:twillio_sid => params["CallSid"]).first.update(:ors => ors_number,
                                                             :outcome => 1)
  #update outcome of call to 1
  # this is a lttle redundant and perhaps will slow us down so may want to remove this later
  Call.where(:phone_number => params["To"]).order(:created_at).last.update(:outcome => 1)

  # set call attempts to zero and reset call number
  pid = Number.where(:id => params['To']).first.pharmacy_id
  Pharmacy.filter(:id => pid).first.reset_pending_calls

  # delete all numbers with delete_me flag equal to zero
  Number.where(:delete_me => 1).delete

  Twilio::TwiML::Response.new do |r|
    r.Play  "#{$base_url}/thank_you_data_recorded_#{$recording_language}.mp3"
    ##r.Say "Thank you for your assistance. Your data has been recorded."
    r.Hangup
  end.text


end

post '/sendsms/:num/:msg' do |num,msg|
  ## TO DO: may want to authenticate via params details
  num = standardize_number(num)
  $client.account.sms.messages.create(
                                     :from => $sms_out_number,
                                     :to => num,
                                     :body => msg
                                     )
end

post '/fallback' do
  $stderr.puts params
  ## TO DO: look at params to figure out error details
  error_message = "#{params['To']} experienced an error (#{params['ErrorCode']})"

  Error.report({
                 :number_id => params['To'],
                 :message => error_message,
                 :code => 7,
                 :created_at => Time.now
               })

  Twilio::TwiML::Response.new do |r|
    r.Play "#{$base_url}/problem_with_system_#{$recording_language}.mp3"
    # r.Say 'An application error has occured. If this is your first time today having an error please try again.  If not, we will be in touch with you shortly to fix the problem.'
  end.text
end

#this runs through each pharmacy and calls a number from each pharmacy that hasn't reported
#this is meant to be hit by a cron job every 10 minutes or so
#max lag is in hours
get '/check_calls/max_lag/:max_lag/max_attempts/:max_attempts' do |max_lag,max_attempts|
  Pharmacy.all.each do |pharmacy|
    $stderr.puts "checking calls for #{pharmacy.id}"
    call = pharmacy.pending_call
    required =  pharmacy.requires_call(max_lag,max_attempts)
    $stderr.puts "call required -->  #{required}"
    if required
      $stderr.puts "redirecting to make call"
      redirect "#{$base_url}/make_call/#{call.number_id}/9"
      $stderr.puts "after redirect"
      nil
    end
  end
  nil
end

# receives forwards from tasker with encodded data
post '/new_sms' do
  sms_number = standardize_number(params['sender'])
  $stderr.puts params['sender']
  message = params['text']
  $stderr.puts "message #{message} \n from #{sms_number}"
  # is this from a staff
  is_staff = $study_staff_numbers.find_all{|name,num| num == sms_number}.size > 0
  # is it from a pharmacy number
  is_pharmacy = Number.where(:id => sms_number).count == 1

  # code who the call came from
  if is_staff
    sms_log_pharm_id = 0
    $stderr.puts "is staff"
  elsif is_pharmacy
    sms_log_pharm_id =  Number.where(:id => sms_number).first.pharmacy_id
  else
    sms_log_pharm_id = -9999
  end

  is_admin = $admin_phone_numbers.find_all{|name,num| num == sms_number}.size > 0
  # log the message
  SmsMessage.insert(:phone_number => sms_number,
                    :message => message,
                    :current_state => 0,
                    :pharmacy_or_staff_id => sms_log_pharm_id,
                    :created_at => Time.now)

  # if we are going to remove a number and the
  $stderr.puts message.grep(/^remove\s*/i).length == 1
  $stderr.puts $admin_phone_numbers.find_all{|name,num| num == sms_number}.size > 0

  # for daily testing pusposes
  if message.grep(/^\s*TESTINGTESTING123\s*$/).length == 1
    $stderr.puts "redirecting daily test sms"
    return confirm_daily_test_sms()
  end

  if message.grep(/^remove\s*/i).length == 1 and is_admin
    $stderr.puts "remove request"
    return remove_number(message,sms_number)
  end

  if message.grep(/^delete\s*pharm/i).length == 1 and is_admin
    $stderr.puts "delete pharm request"
    return delete_pharmacy(message,sms_number)
  end

  # TO DO: should probably make sure it doesn't include more than one of thm
  if message.grep(/\s*reg\s*/i).length == 1 and is_staff
    return register_number(message,sms_number)
  end

  if message.grep(/\s*on\s*/i).length == 1 and is_staff
    $stderr.puts "request to turn number on"
    chopped_message = message.gsub(/on/i,'').split("\s")
    $stderr.puts chopped_message
    # check that it is length 1
    return send_try_again_sms(sms_number) if chopped_message.length != 1
    on_number = standardize_number(chopped_message[0])
    # look in database
    if Number.where(:id => on_number).count > 0
      turn_number(on_number,'on',sms_number)
    else
      send_try_again_sms(sms_number," Either this number is not registered already or you entered it incorrectly.")
    end
    return nil
  end

  if message.grep(/\s*off\s*/i).length == 1 and is_staff
    $stderr.puts "request to turn number off"
    chopped_message = message.gsub(/off/i,'').split("\s")
    # check that it is length 1
    return send_try_again_sms(number) if chopped_message.length != 1
    off_number = standardize_number(chopped_message[0])
    #is number in the db?
    if Number.where(:id => off_number).count > 0
      turn_number(off_number,'off',sms_number)
    else
      send_try_again_sms(sms_number," Either this number is not registered already or you entered it incorrectly.")
    end
    return nil
  end

  if is_pharmacy
    $client.account.sms.messages.create(:from => $sms_out_number,
                                        :to => sms_number,
                                        :body => "Sorry we cannot accept text messages from pharmacies at the moment.")
  end

  $client.account.sms.messages.create(:from => $sms_out_number,
                                      :to => sms_number,
                                      :body => "Error: Sorry we do not understand your request. Please try again.")
  nil
end

#testing SMS reciveal
get '/getsms' do
  twiml = Twilio::TwiML::Response.new do |r|
    callers_number = params['From']
    sms_body = params['Body']
    #check if it is in the system
    number_in_db = Number.first(:id => callers_number)
    $stderr.puts sms_body
    if number_in_db.nil?
      r.Sms "Sorry you do not have a pre-registered number for our system. Please call +880-123-9878 with your pharmacy id to register your number."
    else
      $stderr.puts number_in_db
      ## TO DO: need to test these regexes a bit more
      ors_data = sms_body[/(ors)?.?([0-9]+)/, 2].to_i
      $stderr.puts ors_data

      if ors_data > $max_ors_expected_per_day
        Call.insert(:call_type => 3, :phone_number => params['From'], :outcome => 0,:created_at => Time.now)
        r.Sms "Sorry it seems like you made a mistake. Please try again or if you are having problems, call xxxxxxx"
      else
        Sale.insert(:ors => ors_data, :number_id => params['From'], :pharmacy_id => number_in_db.pharmacy_id,:created_at => Time.now)
        Call.insert(:call_type => 3, :phone_number => params['From'], :outcome => 1,:created_at => Time.now)

        pid = Number.where(:id => params['From']).first.pharmacy_id
        Pharmacy.filter(:id => pid).reset_pending_calls

        r.Sms "Thank you, your data has been recorded"
      end
    end
  end
  twiml.text
end

#main page
get '/' do
  protected!

  #get all sales data for general plot
  ors = Sale.map{|sale| {"y" => sale.ors, "x" => (sale.created_at + 6*3600).to_i,"pid" => sale.pharmacy_id}}.to_json.gsub(/[\"]/i, '').sort_by{|d| d[1]}

  viewPharmacyOptions = Pharmacy.all.map do |pharmacy|
    "
      <option value='#{pharmacy.id}'>
        #{pharmacy.id}-#{pharmacy.name}
      </option>
    "
  end.join("")
  "
    <html>
      <body>
        <h1>welcome to bangpharma</h1>
        select a pharmacy:<br/>
        <select>
          <option></option>
          #{viewPharmacyOptions}
        </select>
        <button>View Pharmacy Contact Details</button>
        <button>Edit Pharmacy Contact Details</button>
        <button>View Pharmacy Numbers</button>
        <button>View Pharmacy Sales</button>
        <button>View Pharmacy Calls</button>
      </body>
      <script src='http://ajax.googleapis.com/ajax/libs/jquery/1.8.1/jquery.min.js'></script>
      <script>
        $('button:contains(View Pharmacy Contact Details)').click(function(){
          var selectedPharmacyId = $('select').val()
          if (selectedPharmacyId == '')
            return
          document.location='#{$base_url}/edit_pharmacy/'+selectedPharmacyId+'?readOnly=true'
        })
        $('button:contains(Edit Pharmacy Contact Details)').click(function(){
          var selectedPharmacyId = $('select').val()
          if (selectedPharmacyId == '')
            return
          document.location='#{$base_url}/edit_pharmacy/'+selectedPharmacyId
        })
        $('button:contains(View Pharmacy Numbers)').click(function(){
          var selectedPharmacyId = $('select').val()
          if (selectedPharmacyId == '')
            return
          document.location='#{$base_url}/numbers/'+selectedPharmacyId
        })
        $('button:contains(View Pharmacy Sales)').click(function(){
          var selectedPharmacyId = $('select').val()
          if (selectedPharmacyId == '')
            return
          document.location='#{$base_url}/sales/'+selectedPharmacyId
        })
        $('button:contains(View Pharmacy Calls)').click(function(){
          var selectedPharmacyId = $('select').val()
          if (selectedPharmacyId == '')
            return
          document.location='#{$base_url}/calls/'+selectedPharmacyId
        })
      </script><br/><br/>
      or choose non-pharmacy specific options: <br/>
        <button>View Latest Activity</button>
        <button>View Errors</button>
        <button>View Daily System Check Data</button>
        <button>Export Sales Data to CSV</button>
      </body>
      <script src='http://ajax.googleapis.com/ajax/libs/jquery/1.8.1/jquery.min.js'></script>
      <script>
        $('button:contains(View Latest Activity)').click(function(){
          document.location='#{$base_url}/recent_activity'
        })
       $('button:contains(View Errors)').click(function(){
          document.location='#{$base_url}/errors'
        })
     $('button:contains(View Daily System Check Data)').click(function(){
          document.location='#{$base_url}/daily_test_data'
        })
     $('button:contains(Export Sales Data to CSV)').click(function(){
          document.location='#{$base_url}/gen_sales_csv'
        })
    </script>
    <br></br>
    <i> total sales  = #{Sale.count} &nbsp &nbsp &nbsp &nbsp &nbsp total pharmacies enrolled = #{Pharmacy.count} &nbsp &nbsp &nbsp &nbsp &nbsp total numbers = #{Number.count}</i>

    <br></br>

<link rel='stylesheet' href='http://code.shutterstock.com/rickshaw/rickshaw.min.css'>
<link type='text/css' rel='stylesheet' href='http://ajax.googleapis.com/ajax/libs/jqueryui/1.8/themes/base/jquery-ui.css'>
<script src='http://d3js.org/d3.v2.js'></script>
<script src='http://code.shutterstock.com/rickshaw/rickshaw.js'></script>

<style>
#chart_container {
        display: inline-block;
        font-family: Arial, Helvetica, sans-serif;
}
#chart {
        float: left;
}
#legend {
        float: left;
        margin-left: 15px;
}
#offset_form {
        float: left;
        margin: 2em 0 0 15px;
        font-size: 13px;
}
#y_axis {
        float: left;
        width: 40px;
}
</style>

<div id='chart_container'>
        <div id='y_axis'></div>
        <div id='chart'></div>
        <div id='legend'></div>
         <form id='offset_form' class='toggler'>
       <!-- #         <input type='radio' name='offset' id='scatterplot' value='' checked>
        #         <label class='scatterplot' for='scatterplot'>scatter plot</label>
        #         <input type='radio' name='offset' id='lines' value='zero'>
        #         <label class='lines' for='lines'>lines</label><br> -->
         </form>
</div>

<script>
var palette = new Rickshaw.Color.Palette();


var graph = new Rickshaw.Graph( {
        element: document.querySelector('#chart'),
        width: 540,
        height: 240,
        renderer: 'scatterplot',
  series: [{
data: #{ors},
color: palette.color(),
                name: 'ORS Sales'
}]
})

var x_axis = new Rickshaw.Graph.Axis.Time( { graph: graph } );

var y_axis = new Rickshaw.Graph.Axis.Y( {
        graph: graph,
        orientation: 'left',
        tickFormat: Rickshaw.Fixtures.Number.formatKMBT,
        element: document.getElementById('y_axis'),
} );

var legend = new Rickshaw.Graph.Legend( {
        element: document.querySelector('#legend'),
        graph: graph
} );

var offsetForm = document.getElementById('offset_form');

offsetForm.addEventListener('change', function(e) {
        var offsetMode = e.target.value;

        if (offsetMode == 'lines') {
                graph.setRenderer('line');
                graph.offset = 'zero';
        } else {
                graph.setRenderer('scatterplot');
                graph.offset = offsetMode;
        }
        graph.render();

}, false);

graph.render();

var hoverDetail = new Rickshaw.Graph.HoverDetail( {
graph: graph,
formatter: function(series, x, y, formattedX, formattedY, d) {
return '&nbsp;' + formattedY;
}
} );

</script>
    </html>
  "
end

get '/sales/:pharmacy_id' do |pharmacy_id|
  protected!
  sales_data = Pharmacy.find(:id => pharmacy_id).sales.reverse_order(:created_at).map do |sale|
    {
      "ors" => sale.ors,
      "report type" => sale.report_type,
      "sale day" => (sale.created_at + 6*3600).strftime("%d/%m/%Y"),
      "sale time" => (sale.created_at + 6*3600).strftime("%I:%M%p"),
      "outcome" => sale.outcome
    }
  end

  #body = sales_data.inspect
  pharm_name = Pharmacy.find(:id => pharmacy_id).name
  rows = sales_data

  headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
  cells = rows.map do |row|
    "<tr>#{row.values.to_cells('td')}</tr>"
  end.join("\n  ")
  table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>#{pharm_name}</title>
</head>
 Sales Data for #{pharm_name} (#{pharmacy_id})
<br> </br>
 #{table}
 </body>
</html>
 "
end

#note this will only show calls from numbers regitered to pharmacies should modify in the future
get '/calls/:pid' do |pharmacy_id|
  protected!
  calls_data = Pharmacy.find(:id => pharmacy_id).calls.reverse_order(:created_at).map do |call|
    {
      "phone number" => call.phone_number,
      "report type" => call.report_type,
      "call day" => (call.created_at + 6*3600).strftime("%d/%m/%Y"),
      "call time" => (call.created_at + 6*3600).strftime("%I:%M%p"),
      "outcome" => call.outcome,
      "call type" => call.call_type
    }
  end

  pharm_name = Pharmacy.find(:id => pharmacy_id).name

  if calls_data.length == 0
    "
<html>
 <body>
<head>
<title>#{pharm_name}</title>
</head>
 Calls for #{pharm_name} (#{pharmacy_id}) [NOTE: at the moment only calls from numbers registered to the pharmacy appear here]
<br> </br>
 No calls from saved numbers made for this pharmacy.
 </body>
</html>
 "
  else
  #body = sales_data.inspect
  rows = calls_data
  $stderr.puts "#{rows} , #{rows.class}"
    headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
    cells = rows.map do |row|
      "<tr>#{row.values.to_cells('td')}</tr>"
    end.join("\n  ")
    table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>#{pharm_name}</title>
</head>
 Calls for #{pharm_name} (#{pharmacy_id}) [NOTE: at the moment only calls from numbers registered to the pharmacy appear here]
<br> </br>
 #{table}
 </body>
</html>
 "
  end
end

get '/numbers/:pid' do |pharmacy_id|
  protected!
  numbers = Number.where(:pharmacy_id => pharmacy_id).reverse_order(:created_at).map do |num|
    {
      "phone number" => num.id,
      "call this number?" => num.call_this_number,
      "created" => (num.created_at + 6*3600).strftime("%d/%m/%Y at %I:%M%p")
    }
  end

  #body = sales_data.inspect
  pharm_name = Pharmacy.find(:id => pharmacy_id).name
  rows = numbers

  headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
  cells = rows.map do |row|
    "<tr>#{row.values.to_cells('td')}</tr>"
  end.join("\n  ")
  table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>#{pharm_name}</title>
</head>
 Numbers for #{pharm_name} (#{pharmacy_id})
<br> </br>
 #{table}
 </body>
</html>
 "
end

get '/recent_activity' do
  protected!
  most_recent_data = Pharmacy.map do |pharm|
    {
      "id" => pharm.id,
      "name" => pharm.name,
      "last sale" => pharm.last_sale.nil? ?  nil : (pharm.last_sale + 3600*6).strftime("%d/%m/%Y at %I:%M%p"),
      "last call" => pharm.last_call.nil? ? nil : (pharm.last_call + 3600*6).strftime("%d/%m/%Y at %I:%M%p")
    }
  end

  rows = most_recent_data

  headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
  cells = rows.map do |row|
    "<tr>#{row.values.to_cells('td')}</tr>"
  end.join("\n  ")
  table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>Most Recent Activity (note you need </title>
</head>
 Most Recent Activity by Pharmacy:
 #{table}
 </body>
</html>
 "
end


get '/errors' do
  protected!
  error_data = Error.reverse_order(:created_at).map do |er|
    {
      "created_at" => er.created_at.nil? ?  nil : (er.created_at + 3600).strftime("%d/%m/%Y at %I:%M%p"),
      "pharmacy" => er.pharmacy.name,
      "number" => er.number_id,
      "error code" => er.code,
      "message" => er.message
    }
  end

if error_data.length == 0
  "
<html>
 <body>
<head>
<title>Pharmacy Reporting Errors</title>
</head>
 Pharmacy Reporting Errors:
<br></br>
 No errors reported yet :-)
 </body>
</html>
 "
else
  rows = error_data
  headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
  cells = rows.map do |row|
    "<tr>#{row.values.to_cells('td')}</tr>"
  end.join("\n  ")
  table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>Pharmacy Reporting Errors</title>
</head>
 Pharmacy Reporting Errors:
<br></br>
 #{table}
 </body>
</html>
 "
end
end

get '/daily_test_data' do
  protected!
  daily_test_data = Test.reverse_order(:created_at).map do |test|
    {
      "id" => test.id,
      "incoming call" => test.incoming_call,
      "incoming sms" => test.incoming_sms,
      "test time" => (test.created_at + 3600*6).strftime("%d/%m/%Y at %I:%M%p"),
    }
  end

if daily_test_data.length == 0
  "
<html>
 <body>
<head>
<title>Daily System Check</title>
</head>
 No Daily System Checks:
<br></br>
 No daily system checks have been run yet.
 </body>
</html>
 "
else
  rows = daily_test_data
  headers = "<tr>#{rows[0].keys.to_cells('th')}</tr>"
  cells = rows.map do |row|
    "<tr>#{row.values.to_cells('td')}</tr>"
  end.join("\n  ")
  table = "<table border=1>
  #{headers}
  #{cells}
</table>"

  "
<html>
 <body>
<head>
<title>Daily System Check </title>
</head>
 Daily System Check:
 #{table}
 </body>
</html>
 "
end
end

get '/new_pharmacy' do
  protected!
  # make new pharmacy entry and get pid
  Pharmacy.insert()
  pharmacy_id = Pharmacy.order(:id).last.id

  Number.insert(
                :created_at => Time.now,
                :pharmacy_id => pharmacy_id
                )

  AvailableTime.insert(
                       :pharmacy_id => pharmacy_id,
                       :start_time => "09:00",
                       :end_time => "21:00"
  )


  redirect "#{$base_url}/edit_pharmacy/#{pharmacy_id}"
end

get '/edit_pharmacy/:pharmacy_id' do |pharmacy_id|
  protected!
  pharmacy = Pharmacy.filter(:id => pharmacy_id).first
  numbers = Number.filter(:pharmacy_id => pharmacy_id)
  times = AvailableTime.filter(:pharmacy_id => pharmacy_id)

  result = haml :edit_pharmacy, :locals => {
    :saved => params["saved"],
    :pharmacy_id => pharmacy.id,
    :pharmacy_name => pharmacy.name,
    :lat => pharmacy.latitude,
    :long => pharmacy.longitude,
    :contact_times => times.map{|time| "#{time.start_time.strftime('%H:%M')}-#{time.end_time.strftime('%H:%M')}" }.join(", "),
    :numbers => numbers.map{|number| number.id }.join(", ")
  }
  if params["readOnly"] == "true"
    result += "
      <script>
        $('form :input').attr('disabled', true);
      </script>
    "
  end
  result
end

post '/edit_pharmacy' do
  protected!
  pharmacy = Pharmacy.filter(:id => params["pharmacy_id"]).first
  # Delete all of these and then recreate based on what was passed in
  numbers = Number.filter(:pharmacy_id => params["pharmacy_id"]).delete
  times = AvailableTime.filter(:pharmacy_id => params["pharmacy_id"]).delete

  pharmacy.update(
    :name => params["pharmacy_name"],
    :preferred_number_id => params["numbers"].split(/, */).first,
    :latitude => params["lat"],
    :longitude =>  params["long"]
  )

  params["numbers"].split(/, */).each do |number|
    Number.insert(
                  :id => number,
                  :pharmacy_id => pharmacy.id,
                  :call_this_number => 1,
                  :created_at => Time.now
                  )
  end

  # TODO Need to do some conversion here to create times, or remove time object from database
  params["contact_times"].split(/, */).each do |time_range|
    (start_time, end_time) = time_range.split(/-/)
    AvailableTime.insert(
      :pharmacy_id => pharmacy.id,
      :start_time => "#{start_time}:00",
      :end_time => "#{end_time}:00"
    )
  end

  if pharmacy.pending_call.nil?
    # initialize pending call entry only if there isn't an entry already
    PendingCall.insert(
                       :number_id => pharmacy.preferred_number_id,
                       :attempts => 0
                       )
  end

  #TODO
  #Check for conflicts

  #anyone_with_same_number = Pharmacy.filter(
  #                                          :preferred_number_id => prim_number
  #                                          )

  #if pharm.count != 0 or anyone_with_same_number.count != 0
  #  haml :pharmacy_already_entered
  #else
  redirect "#{$base_url}/edit_pharmacy/#{pharmacy.id}?saved=true"
end

get '/display_pharm/pid/:pid' do |pid|
  protected!
  pharm = Pharmacy.filter(:id => pid).first
  numbers = Number.filter(:pharmacy_id => pid)
  times = AvailableTime.filter(:pharmacy_id => pid)

  name = pharm.name
  primary_number = pharm.preferred_number_id
  lat = pharm.latitude
  long = pharm.longitude

  number_array = numbers.map do |num|
    {
      "number" => num.id,
      "created at" => num.created_at,
      "call this number?" => num.call_this_number
    }
  end

  haml :display_pharmacy_contact_info
end

get '/new_pharmacy_to_database' do
  $stderr.puts params
end

## this is meant to be a d for this pharmacy
get '/pharmacy_overview/:pharm_id' do |pharm_id|

end

#this runs some daily checks
get '/daily_test' do
  # create a new Test record
  Test.insert(:created_at => Time.now)
  $stderr.puts "calling phone"
  $client.account.calls.create(
                               :from => $sms_out_number, #going to be a twillio number
                               :to => $caller_id_number, #bangpharma number
                               :url => "#{$base_url}/daily_incoming_call",
                               :timeout => 10
                               )

  $client.account.sms.messages.create(
                                      :from => $sms_out_number,
                                      :to => $caller_id_number,
                                      :body => "TESTINGTESTING123")
  nil
end

post '/daily_incoming_call' do
$stderr.puts "recieving daily incoming call"
Test.order(:created_at).last.update(:incoming_call => 1)
Twilio::TwiML::Response.new do |r|
  r.Say 'hi'
  r.Hangup
end.text
 nil
end


#used to send an sms to all admins or staff
get '/sms_to_group/group/:group/message/:message' do |group,mes|
  if group == "admin"
    $admin_phone_numbers.each do |name,num|
      $client.account.sms.messages.create(
                                          :from => $sms_out_number,
                                          :to => num,
                                          :body => mes)
    end
  end

  if group == "staff"
    $study_staff_numbers.each do |name,num|
      $client.account.sms.messages.create(
                                          :from => $sms_out_number,
                                          :to => num,
                                          :body => mes)
    end
  end
  nil
end


# # used to generate csv of sales table
get '/gen_sales_csv' do

headers "Content-Disposition" => "attachment;filename=bangpharma_sales_#{Time.now.strftime("%Y-%m-%d")}.csv",
    "Content-Type" => "application/octet-stream"

all_sales = Sale.all.map do |sale|
  [sale.ors,sale.created_at,sale.pharmacy_id,sale.number_id,sale.outcome,sale.report_type]
end

# add col names to the first element
all_sales.unshift('sale.ors,sale.created_at,sale.pharmacy_id,sale.number_id,sale.outcome,sale.report_type'.split(/, */))

CSV.generate() do |csv|
  all_sales.each do |row|
    csv << row
  end
end
end
