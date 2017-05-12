#!/usr/bin/env ruby
  # == Synopsis  
  # WARNING WARNING THIS IS NOT READY FOR USE.
  #
  # This script is designed to automate security analysis of a Kubernetes cluster based on the CIS Kubernetes Standard
  # it makes use of kubeclient - https://github.com/abonas/kubeclient to access the API
  # At the moment it works best for installations that run the API server in a pod as that makes it easy to query the command line options
  #
  # Best way to access it us use a kubeconfig file as this contains all the information needed.
  # Options are also there for providing tokens to access, but they're a bit more awkward to use.
  #
  # == Author
  # Author::  Rory McCune
  # Copyright:: Copyright (c) 2017 Rory Mccune
  # License:: GPLv3
  #
  # This program is free software: you can redistribute it and/or modify
  # it under the terms of the GNU General Public License as published by
  # the Free Software Foundation, either version 3 of the License, or
  # (at your option) any later version.
  #
  # This program is distributed in the hope that it will be useful,
  # but WITHOUT ANY WARRANTY; without even the implied warranty of
  # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  # GNU General Public License for more details.
  #
  # You should have received a copy of the GNU General Public License
  # along with this program.  If not, see <http://www.gnu.org/licenses/>.
  #
  # == Options
  #   -h, --help                                    Displays help message
  #   -v, --version                                 Display the version, then exit
  #   -c <file>, --config <file>                    Specify a kubeconfig file to use for connection to the API server
  #   -r <file>, --report <file>                    Name of file for reporting
  #   --reportDirectory <dir>                       Place the report in a different directory
  #   -t <token>, --token <token>                   Specify an auth. token to use
  #   -f <token_file>, --token_file <token_file>    Specify a file to read an authentication token from
  #   -s, --server                                  The target server to connect to in the format https://server_ip:server_port. Not needed if a config file is used
  #
  # == Usage 
  #
  #   kubernetesanalyzer.rb -c <kubeconfigfile> -r <reportfile>
  
class KubernetesAnalyzer
    VERSION = '0.0.1'

  def initialize(commmand_line_opts)
    @options = commmand_line_opts
    require 'logger'
    begin
      require 'kubeclient'
    rescue LoadError
      puts "You need to install kubeclient for this, try 'gem install kubeclient'"
      exit
    end

    @base_dir = @options.report_directory
    if !File.exists?(@base_dir)
      Dir.mkdirs(@base_dir)
    end

    @log = Logger.new(@base_dir + '/kube-analyzer-log.txt')
    @log.level = Logger::DEBUG
    @log.debug("Log created at " + Time.now.to_s)
    @log.debug("Target API Server is " + @options.target_server)

    @report_file_name = @base_dir + '/' + @options.report_file
    @report_file = File.new(@report_file_name + '.txt','w+')
    @html_report_file = File.new(@report_file_name + '.html','w+')
    @log.debug("New Report File created #{@report_file_name}")
  end

  def run
    @results = Hash.new
    #TODO: Expose this as an option rather than hard-code to off
    unless @options.config_file
      ssl_options = { verify_ssl: OpenSSL::SSL::VERIFY_NONE}
      #TODO: Need to setup the other authentication options
      if @options.token.length > 1
        auth_options = { bearer_token: @options.token}
      elsif @options.token_file.length > 1
        auth_options = { bearer_token_file: @options.token_file}
      else
        #Not sure this will actually work for no auth. needed, try and ooold cluster to check
        auth_options = {}
      end
      @results[@options.target_server] = Hash.new
      @client = Kubeclient::Client.new @options.target_server, 'v1', auth_options: auth_options, ssl_options: ssl_options
    else
      config = Kubeclient::Config.read(@options.config_file)
      @client = Kubeclient::Client.new(
        config.context.api_endpoint,
        config.context.api_version,
        {
          ssl_options: config.context.ssl_options,
          auth_options: config.context.auth_options
        }
      )
      #We didn't specify the target on the command line so lets get it from the config file
      @options.target_server = config.context.api_endpoint
      @results[config.context.api_endpoint] = Hash.new
    end
    #Test response
    begin
      @client.get_pods.to_s
    rescue
      puts "whoops that didn't go well"
      exit
    end
    test_api_server
    report
    if @options.html_report
      html_report
    end
  end

  def test_api_server
    target = @options.target_server
    @results[target]['api_server'] = Hash.new
    @results[target]['evidence'] = Hash.new
    pods = @client.get_pods
    pods.each do |pod| 
      #Ok this is a bit naive as a means of hitting the API server but hey it's a start
      if pod['metadata']['name'] =~ /kube-apiserver/
        @api_server = pod
      end
    end
    
    api_server_command_line = @api_server['spec']['containers'][0]['command']

    #Check for Allow Privileged
    unless api_server_command_line.index{|line| line =~ /allow-privileged=false/}
      @results[target]['api_server']['CIS 1.1.1 - Ensure that the --allow-privileged argument is set to false'] = "Fail"
    end

    #Check for Anonymous Auth
    unless api_server_command_line.index{|line| line =~ /anonymous-auth=false/}
      @results[target]['api_server']['CIS 1.1.2 - Ensure that the --anonymous-auth argument is set to false'] = "Fail"
    end

    #Check for Basic Auth
    if api_server_command_line.index{|line| line =~ /basic-auth-file/}
      @results[target]['api_server']['CIS 1.1.3 - Ensure that the --basic-auth-file argument is not set'] = "Fail"
   end

    #Check for Insecure Allow Any Token
    if api_server_command_line.index{|line| line =~ /insecure-allow-any-token/}
      @results[target]['api_server']['CIS 1.1.4 - Ensure that the --insecure-allow-any-token argument is not set'] = "Fail"
    end

    #Check to confirm that Kubelet HTTPS isn't set to false
    if api_server_command_line.index{|line| line =~ /kubelet-https=false/}
      @results[target]['api_server']['CIS 1.1.5 - Ensure that the --kubelet-https argument is set to true'] = "Fail"
    end

    #Check for Insecure Bind Address
    if api_server_command_line.index{|line| line =~ /insecure-bind-address/}
      @results[target]['api_server']['CIS 1.1.6 - Ensure that the --insecure-bind-address argument is not set'] = "Fail"
    end

    #Check for Insecure Bind port
    unless api_server_command_line.index{|line| line =~ /insecure-bind-port=0/}
      @results[target]['api_server']['CIS 1.1.7 - Ensure that the --insecure-port argument is set to 0'] = "Fail"
    end

    #Check Secure Port isn't set to 0
    if api_server_command_line.index{|line| line =~ /secure-port=0/}
      @results[target]['api_server']['CIS 1.1.8 - Ensure that the --secure-port argument is not set to 0'] = "Fail"
    end




    @results[target]['evidence']['api_server'] = api_server_command_line
  end

  def report
    @report_file.puts "Kubernetes Analyzer"
    @report_file.puts "===================\n\n"
    @report_file.puts "**Server Reviewed** : #{@options.target_server}"
    @report_file.puts "\n\nAPI Server Results"
    @report_file.puts "----------------------\n\n"
    @results[@options.target_server]['api_server'].each do |test, result|
      @report_file.puts '* ' + test + ' - **' + result + '**'
    end
    @report_file.puts "\n\nEvidence"
    @report_file.puts "---------------\n\n"
    @report_file.puts '    ' + @results[@options.target_server]['evidence']['api_server'].to_s
    @report_file.close
  end

  def html_report
    begin
      require 'kramdown'
    rescue LoadError
      puts "HTML Report needs Kramdown"
      puts "Try 'gem install kramdown'"
      exit
    end
    base_report = File.open(@report_file_name + '.txt','r').read
    puts base_report.length.to_s
    report = Kramdown::Document.new(base_report)
    @html_report_file << '
        <!DOCTYPE html>
      <head>
       <title> Kubernetes Analyzer Report</title>
       <meta charset="utf-8"> 
       <style>
        body {
          font: normal 14px auto "Trebuchet MS", Verdana, Arial, Helvetica, sans-serif;
          color: #4f6b72;
          background: #E6EAE9;
        }
        #kubernetes-analyzer {
          font-weight: bold;
          font-size: 48px;
          font-family: "Trebuchet MS", Verdana, Arial, Helvetica, sans-serif;
          color: #4f6b72;
        }
        #api-server-results {
          font-weight: italic;
          font-size: 36px;
          font-family: "Trebuchet MS", Verdana, Arial, Helvetica, sans-serif;
          color: #4f6b72;
        }
         th {
         font: bold 11px "Trebuchet MS", Verdana, Arial, Helvetica, sans-serif;
         color: #4f6b72;
         border-right: 1px solid #C1DAD7;
         border-bottom: 1px solid #C1DAD7;
         border-top: 1px solid #C1DAD7;
         letter-spacing: 2px;
         text-transform: uppercase;
         text-align: left;
         padding: 6px 6px 6px 12px;
         }
      td {
        border-right: 1px solid #C1DAD7;
        border-bottom: 1px solid #C1DAD7;
        background: #fff;
        padding: 6px 6px 6px 12px;
        color: #4f6b72;
      }
      td.alt {
        background: #F5FAFA;
        color: #797268;
      }
    </style>
  </head>
  <body>
    '
    @html_report_file.puts report.to_html
    @html_report_file.puts '</body></html>'
  end

end


if __FILE__ == $0
  require 'ostruct'
  require 'optparse'
  options = OpenStruct.new

  options.report_directory = Dir.pwd
  options.report_file = 'kube-parse-report'
  options.target_server = 'http://127.0.0.1:8080'
  options.html_report = false
  options.token = ''
  options.token_file = ''
  options.config_file = false

  opts = OptionParser.new do |opts|
    opts.banner = "Kubernetes Auto Analyzer #{KubernetesAnalyzer::VERSION}"

    opts.on("-s", "--server [SERVER]", "Target Server") do |serv|
      options.target_server = serv
    end

    #TODO: Need options for different authentication mechanisms      
    opts.on("-c", "--config [CONFIG]", "kubeconfig file to load") do |file|
      options.config_file = file
    end

    opts.on("-t", "--token [TOKEN]", "Bearer Token to Use") do |token|
      options.token = token
    end

    opts.on("-f", "--token_file [TOKENFILE]", "Token file to use (provide full path)") do |token_file|
      options.token = token_file
    end
      
    opts.on("-r", "--report [REPORT]", "Report name") do |rep|
      options.report_file = rep + '_kube'
    end

    opts.on("--html_report", "Generate an HTML report as well as the txt one") do |html|
      options.html_report = true
    end

    opts.on("--reportDirectory [REPORTDIRECTORY]", "Report Directory") do |rep|
      options.report_directory = rep
    end

    opts.on("-h", "--help", "-?", "--?", "Get Help") do |help|
      puts opts
      exit
    end
      
    opts.on("-v", "--version", "get Version") do |ver|
      puts "Kubernetes Analyzer Version #{KubernetesAnalyzer::VERSION}"
      exit
    end
  end

  opts.parse!(ARGV)

  unless (options.token.length > 1 || options.config_file || options.token_file.length > 1)
    puts "No valid auth mechanism specified"
    puts opts
    exit
  end

  analysis = KubernetesAnalyzer.new(options)
  analysis.run
end