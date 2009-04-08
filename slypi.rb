require "rubygems"
require "hpricot"
require "mongrel"
require "yaml"
require "json"
require "fileutils"

require "open-uri" # Temporary Require

class String
  def inner_text;self;end
end

class FunctionServer < Mongrel::HttpHandler
  def initialize(functionspec)
    @spec = functionspec
  end
  
  def process(req,res)
    if (not req.params['PATH_INFO'] =~ /([a-z]+)/)
      res.start(301) do |head,out|
        head['Location'] = req.params['SCRIPT_NAME']
        out.write "Invalid request, redirecting"
      end
      return
    end
    format = $1
    # Make sure we have all the required parameters, and that they match
    @params = Mongrel::HttpRequest.query_parse(req.params['QUERY_STRING'])
    begin
      @spec['requires'].each do |needed|
        raise NoMethodError if not @params[needed[0]].match(needed[1]['format'])
      end
    rescue NoMethodError
      res.start(417) do |head,out|
        # ToDo: link to documentation
        out.write "You have not given me all the required components. You can find documentation for this api on the <a href=\"#{req.params['SCRIPT_NAME']}\">api about page</a>" 
      end
      return
    end
    
    @spec['optional'].each { |opt|
      begin
        raise NoMethodError if not @params[opt[0]].match(opt[1]['format'])
      rescue NoMethodError
        @params[opt[0]] = opt[1]['default']
      end
    } if not @spec['optional'].nil?
    
    # Preparation Complete
    
    reqid = (req.params['SCRIPT_NAME'].gsub(/\/apis\/(.+)\/(.+)\./,"cache/\\1/\\2/"))+@params.sort.collect{|param| URI.encode(param[0].to_s)+"="+URI.encode(param[1].to_s)}.join("&")+".yaml"
    begin
      # Check cache timestamp
      output = YAML::load(open(reqid))
      # Add cache timestamp
    rescue
      url = subst(@spec['request']['url'],true)

      begin
        page = Hpricot(open(url))
      rescue
        res.start(503) do |head,out|
          out.write "There was an error retrieving the data from the internet"
        end
        return
      end

      output = traverse(page,@spec['returns'])

      output['sourceURL'] = url
      
      open(reqid,"w") do |f|
        f.write YAML::dump(output)
      end
    end
    
    res.start(200) do |head,out|
      case req.params['PATH_INFO']
      when "json"
        begin
          out.write output.to_json
        rescue JSON::GeneratorError
          out.write "The JSON encoder has thrown a wobbly. At the moment it doesn't like unicode characters, we're working on fixing this. Why not try getting this data in another format?"
        end
      when "yaml"
        out.write YAML::dump(output)
      else
        out.write "# You have not specified a correct format (#{req.params['PATH_INFO']}). Your data is below, but in YAML"
        out.write YAML::dump(output)
      end
    end
  end
  
  private
  
  def traverse(root,items)
    output = {}
    items.each do |item|
      if item[1].include? "_base"
        cont = item[1].reject{|key,val| key == "_base"}
        output[item[0]] = root.search(item[1]["_base"]).collect{ |hits| traverse(hits,cont) }
      else
        begin
          if item[1]['xpath'] =~ /\/attribute::([a-z]+)$/
            el = (((els = root.search(subst(item[1]['xpath'].gsub(/\/attribute::([a-z]+)/,"")))).length < 2) ? els[0].attributes[$1] : els.collect{|e| e.attributes[$1]})
          else
            el = root.search(subst(item[1]['xpath']))
          end

          if item[1]['regex'].nil?
            output[item[0]] = (el.is_a?(String) or el.length < 2) ? el.inner_text.strip : el.collect{|e| e.inner_text.strip}
          else
            # Here I need to deal with unicode characters like \x96 for the JSON, trial with showid=3613
            output[item[0]] = (el.is_a?(String) or el.length < 2) ?
              el.inner_text.strip.match(Regexp.new(subst(item[1]['regex']),Regexp::MULTILINE))[1] :
              el.collect{ |e|
                e.inner_text.strip.match(Regexp.new(subst(item[1]['regex']),Regexp::MULTILINE))[1]
              }
          end
        rescue NoMethodError
        end
      end
    end
    return output
  end
  
  def subst(input,urlencode = false)
    return input if input.match(/%\{[a-zA-Z0-9]+\}/).nil?
    string = input
    @params.each do |param|
      string = string.gsub(/%\{#{param[0]}\}/,URI::encode(param[1].to_s))
    end
    return string
  end
end

class AboutServer < Mongrel::HttpHandler
  def initialize(about)
    @about = about
  end
  
  def process(req,res)
    if (not req.params['PATH_INFO'] == "") and (not req.params['PATH_INFO'] == "/")
      res.start(301) do |head,out|
        head['Location'] = req.params['SCRIPT_NAME']
        out.write "Invalid request, redirecting"
      end
      return
    end
    res.start(200) do |head,out|
      out.write YAML::dump(@about)
    end
  end
end

class ApisServer < Mongrel::HttpHandler
  def process(req,res)
    res.start(200) do |head,out|
      head['Content-type'] = "text/html"
      out.write "<h1>List of Installed APIs</h1><pre>"
      out.write YAML::dump($apis)
      out.write "</pre>"
    end
  end
end

class InstallServer < Mongrel::HttpHandler
  def process(req,res)
    res.start(501) do |head,out|
      out.write "Sorry guys, I've not yet implemented live-installations!"
    end
  end
end

def installAPI(api)
  $apis[api['slypi_internal_name']] = api['About']
  
  $server.register("/apis/"+api['slypi_internal_name'],AboutServer.new(api['About']))
  api['Functions'].each do |function|
    $server.register("/apis/#{api['slypi_internal_name']}/#{function[0]}.",FunctionServer.new(function[1]))
    FileUtils.mkdir_p("cache/#{api['slypi_internal_name']}/#{function[0]}/")
  end
end


# Initialization Section

$apis = {}

$stdout.puts "Server initializing..."
begin
  $server = Mongrel::HttpServer.new("127.0.0.1", "15685")
rescue Errno::EADDRINUSE
  begin
    $stderr.puts "Error: You seem to have another copy of SlyPI running already. Please close it before trying again." if open("http://127.0.0.1:15685/version").read.match(/^SlyPI/)
  rescue
    $stderr.puts "Error: You appear to have another service running on port 15685.\n       It does not appear to be a copy of SlyPI, please close that application before running SlyPI again."
  end
  Process.exit()
end
$server.register("/",Mongrel::DirHandler.new("./docs/"))

Dir.glob("apis/*.api").each do |apifile|
  api = YAML::load(open(apifile).read)
  if (not api['About'].nil?) and api['Functions'].length > 0
    api['slypi_internal_name'] = apifile.gsub(/^apis\/(.+)\.api$/,'\\1')
    installAPI(api)
    $stdout.puts " - Loaded module '#{api['slypi_internal_name']}'"
  else
    $stderr.puts "Error: The SlyPI '#{apifile}' failed to load correctly. It appears to be an invalid file."
  end
end

$server.register("/apis",ApisServer.new)

warn "Warning: Live install features are not implemented yet!"
$server.register("/install/",InstallServer.new)

$stdout.puts "Server started! Please check http://127.0.0.1:15685/ for information."

killServer = Proc.new {
  $stdout.puts "Closing the SlyPI server"
  $server.stop
  $stdout.puts " - All good, Sayounara!"
}

Signal.trap("INT",killServer)
Signal.trap("TERM",killServer)
Signal.trap("HUP") { $stdout.puts "HUP signal caught, keeping the server running" }

$server.run.join