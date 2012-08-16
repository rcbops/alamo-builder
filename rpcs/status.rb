#!/opt/chef/embedded/bin/ruby

require 'mixlib/cli'
require 'chef'
require 'chef/node'
require 'chef/mixin/xml_escape'
require 'json'
require 'ipaddr'
require "curses"

config_file=ARGV[0]

class CursesWindow
  attr_reader :parent, :x, :y, :window, :width, :height
  attr_reader :border, :horizontal_pad, :vertical_pad

  WINDOW_RED = 1
  WINDOW_BLUE = 2

  def initialize(options={})
    @parent = options[:parent] || nil
    @x = options[:x] || 0
    @y = options[:y] || 0
    @width = options[:width] || 10
    @height = options[:height] || 5
    @border = options[:border]
    if @border.nil?
      @border = true
    end

    @title = options[:title]
    @color = options[:color] || 2
    @border_color = options[:border_color] || @color
    @horizontal_pad = options[:horizontal_pad] || 1
    @vertical_pad = options[:vertical_pad] || 0

    if @border
      @border_window = Curses::Window.new(@height, @width, global_y, global_x)
      @border_window.attron(Curses.color_pair(@border_color))

      @border_window.box(0,0)
      if @title
        xpos = (@width - @title.length) / 2
        @border_window.setpos(0, xpos - 1)
        @border_window.addstr(" " + @title + " ")
        _refresh_border
      end

      @window = Curses::Window.new(@height - 2, @width - 2,
                                   global_y + 1, global_x + 1)
    else
      @border_window = nil
      @window = Curses::Window.new(@height, @width, global_y, global_x)
    end

    clear
    @subwindows=[]
    refresh
  end

  def usable_width
    width = @width - (@horizontal_pad * 2)
    if(@border)
      width = width - 2
    end
    width
  end

  def attron(attrs)
    @window.attron(attrs)
  end

  def attroff(attrs)
    @window.attroff(attrs)
  end

  def clear
    # @window.clear
    @window.bkgdset(Curses.color_pair(@color))
    @window.attron(Curses.color_pair(@color))

    # some curses apparently don't clear windows right, or reset the attrs... or something
    (0..@height).each do |line|
      @window.setpos(line,0)
      @window.addstr " " * @width
    end
  end

  def usable_height
    height = @height - (@vertical_pad * 2)
    if(@border)
      height = height - 2
    end
    height
  end

  def global_x
    g_x = @x

    if @parent
      g_x = g_x  + @parent.global_x + @parent.horizontal_pad
      if @parent.border
        g_x += 1
      end
    end
    g_x
  end

  def global_y
    g_y = @y

    if @parent
      g_y += @parent.global_y + @parent.vertical_pad
      if @parent.border
        g_y += 1
      end
    end

    g_y
  end

  def subwindow(options={})
    options[:parent] = self
    new_window = CursesWindow.new(options)
    @subwindows << new_window
    new_window
  end

  def getch
    @window.getch
  end

  def setpos(x, y)
    @window.setpos(y + @vertical_pad, x + @horizontal_pad)
  end

  def puts(str)
    @window.addstr(str)
    @window.noutrefresh
  end

  def putstr(x, y, str)
    setpos(x, y)
    puts(str)
  end


  def _refresh_border
    if @border_window
      @border_window.noutrefresh
    end
  end

  def refresh
    @window.noutrefresh
    @subwindows.each do |subwindow|
      subwindow.refresh
    end
  end
end

class MainWindow < CursesWindow
  def initialize(options={})
    options[:width] = options[:width] || Curses.cols
    options[:height] = options[:height] || Curses.lines

    super(options)
  end
end

class Renderer
  def initialize(window)
    @window = window
  end

  def render_hash(hash, x,  y, options={})
    pos=0

    hash.each_pair do |k,v|
      if v.class == Hash
        @window.putstr(0, pos + y, k)
        render_hash(v, x + 1, pos + y + 1, options)
        pos += v.count + 2
      else
        @window.attron(Curses::A_BOLD)
        @window.putstr(x, y + pos, k + ":")
        @window.attroff(Curses::A_BOLD)
        @window.putstr(x + @window.usable_width - (v.to_s.length + 1), y + pos, v.to_s)
        pos += 1
      end
    end

    pos
  end

  def render()
  end
end

class ChefRenderer < Renderer
  def initialize(file, window)
    super(window)

    Chef::Config.from_file(file)

    @api_endpoint = ""
    @dashboard_endpoint = ""
    @hostname = `hostname -f`.chomp
    @version = "Unknown"

    begin
      File.open("/opt/rpcs/version.cfg", "r") do |file|
        info = file.inject({}) do |hash, line|
          key, value = line.split("=")
          if key and value
            hash.merge(key.strip => value.strip)
          else
            hash
          end
        end
        @version = "#{info["major_version"]}"
        @version += "-#{info["minor_version"]}" if info["minor_version"]
        @version += " \"#{info["codename"]}\"" if info["codename"]
      end
    rescue
      @version = "Unknown"
    end
  end

  def _get_ip_for_net(network, node)
    if not (node.has_key?("osops_networks") and node["osops_networks"].has_key?(network)) then
      return node["ipaddress"]
    end

    net = IPAddr.new(node["osops_networks"][network])
    node["network"]["interfaces"].each do |interface|
      interface[1]["addresses"].each do |k,v|
        if v["family"] == "inet6" or v["family"] == "inet" then
          addr=IPAddr.new(k)
          if net.include?(addr) then
            return [interface[0],k]
          end
        end
      end
    end
  end

  def get_info()
    # find the api endpoints
    begin
      @node_info = { "infra" => [], "compute" => [] }

      Chef::Node.list(true).each do |node_array|
        node = node_array[1]
        if node.name == @hostname
          @node_info["self"] = node
        end

        if node[:roles].include?("single-controller")
          @node_info["infra"] << node[:fqdn]
          @api_endpoint = "http://#{_get_ip_for_net("public", node)[1]}:5000"
          @dashboard_endpoint = "https://#{_get_ip_for_net("public", node)[1]}"
        end

        if node[:roles].include?("single-compute")
          @node_info["compute"] << node[:fqdn]
        end
      end
    rescue
      return False
    end
  end

  def render()
    if get_info
      @window.clear
      @window.attron(Curses::A_BOLD)
      @window.putstr(0, 0, "Chef Status")
      @window.attroff(Curses::A_BOLD)

      last_run = Time.now.to_i - @node_info["self"]["ohai_time"].to_i
      last_run_units="seconds"

      { "minutes" => 60, "hours" => 60, "days" => 24 }.each do |k,v|
        break if (last_run / v) < 1
        last_run_units = k
        last_run = last_run / v
      end

      display_hash = {
        "Cluster" => {
          "API" => @api_endpoint,
          "Dash" => @dashboard_endpoint,
          "Infra Nodes" => @node_info["infra"].count,
          "Compute Nodes" => @node_info["compute"].count,
        },
        "Other" => {
          "Last Run" => "#{last_run} #{last_run_units} ago",
          "Platform" => @node_info["self"]["platform"] + " " + @node_info["self"]["platform_version"],
          "IP Address" => @node_info["self"]["ipaddress"],
          "MAC Address" => @node_info["self"]["macaddress"]
        }
      }

      render_hash(display_hash, 0, 2)
      verstring = "Ver: #{@version}"
      offset = @window.usable_width - verstring.length

      @window.attron(Curses::A_BOLD)
      @window.putstr(offset, @window.usable_height - 1, verstring)
      @window.attroff(Curses::A_BOLD)


    end
  end
end

class StatusRenderer < Renderer
  def initialize(window)
    super(window)
  end

  def get_info()
    @hostname = `hostname -f`.chomp
    @memtotal = `cat /proc/meminfo | grep "MemTotal" | awk '{ print $2 }'`.chomp
    @memfree = `cat /proc/meminfo | grep "MemFree" | awk '{ print $2 }'`.chomp
    @vms = `virsh list | grep " [0-9]" | wc -l`.chomp
    @loadavg = `cat /proc/loadavg`.chomp.split(" ").take(3).join(", ")
    @procs = `cat /proc/cpuinfo | grep processor | wc -l`.chomp
    @df=`df -h /var | grep -v Filesystem`.chomp.split
    @uname = `uname -r`.chomp
  end

  def render()
    get_info

    hash_blocks = {
      "General" => {
        "Hostname" => @hostname,
        "Kernel" => @uname
      },
      "Memory" => {
        "Total Memory" => @memtotal + " Kb",
        "Free Memory" => @memfree + " Kb"
      },
      "Proc" => {
        "Procs" => @procs,
        "Load Average" => @loadavg
      },
      "Disk" => {
        "Instance data (total)" => @df[1],
        "Instance data (free)" => @df[3],
      }
    }


    @window.attron(Curses::A_BOLD)
    @window.putstr(0, 0, "Host Status")
    @window.putstr(0, @window.usable_height - 1, `date`.strip)
    @window.attroff(Curses::A_BOLD)

    render_hash(hash_blocks, 0, 2)
  end
end


Curses.init_screen
Curses.start_color
Curses.cbreak
Curses.noecho
Curses.curs_set(0)
Curses.init_pair(1, Curses::COLOR_WHITE, Curses::COLOR_BLUE)
Curses.init_pair(2, Curses::COLOR_BLACK, Curses::COLOR_BLUE)
Curses.init_pair(3, Curses::COLOR_BLACK, Curses::COLOR_WHITE)

main = MainWindow.new(:border => false,
                      :color => 0,
                      :horizontal_pad => 0)

config_window = main.subwindow(:title => "Configuration",
                               :x => 0,
                               :y => 0,
                               :width => main.usable_width,
                               :color => 1,
                               :border_color => 2,
                               :horizontal_pad => 0,
                               :height => main.usable_height - 1)

left_window = config_window.subwindow(:border => false,
                                      :color => 1,
                                      :border_color => 2,
                                      :width => config_window.usable_width / 2,
                                      :height => config_window.usable_height,
                                      :horizontal_pad => 2,
                                      :x => 0,
                                      :y => 0)

right_window = config_window.subwindow(:border => false,
                                       :color => 0,
                                       :width => config_window.usable_width / 2,
                                       :height => config_window.usable_height,
                                       :horizontal_pad => 2,
                                       :x => config_window.usable_width / 2,
                                       :y => 0)

status_window = main.subwindow(:border => false,
                               :color => 3,
                               :width => main.usable_width,
                               :height => 1,
                               :x => 0,
                               :y => main.usable_height - 1)

status_window.setpos(0,0)
status_window.puts("Rackspace (TM) Private Cloud Software.  Press Alt-F2 for a terminal")

right_renderer = ChefRenderer.new(config_file, right_window)
left_renderer = StatusRenderer.new(left_window)


begin
  begin
    right_renderer.render
  rescue
  end
  (1..5).each do
    left_renderer.render
    Curses.doupdate
    sleep 60
  end
end while 1
