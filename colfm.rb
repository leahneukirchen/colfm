# -*- coding: utf-8 -*-
require 'curses'
require 'etc'
require 'pp'

=begin
TODO:
- select multiple files, and operate on them
- select files by regexp (%)
- find favorites from mounts etc.
- compressed files?
- last column more detailed?
- bring selected directory/files back to shell
=end

$dotfiles = false
$backup = true
$sidebar = false

$columns = []

$marked = []

$pwd = ""

MIN_COL_WIDTH = 8
MAX_COL_WIDTH = 20
MAX_ACTIVE_COL_WIDTH = 35
SIDEBAR_MIN_WIDTH = 20

FAVORITES = [["/", "/"],
             ["~", "~"],
             ["~/Desktop", "Desktop"]]

RCFILE = File.expand_path("~/.colfmrc")

$sort = 1
$reverse = false

begin
  load RCFILE
rescue LoadError
end

class Directory
  attr_reader :dir
  attr_accessor :cur
  attr_accessor :parent

  def initialize(dir)
    @dir = dir
    @cur = 0

    refresh
  end

  def active?
    $active == self
  end

  def refresh
    @entries = Dir.entries(@dir).
    delete_if { |f| f =~ /^\./ && !$dotfiles }.
    delete_if { |f| f =~ /~\z/ && !$backup }.
    map { |f|
      FileItem.new(File.join(@dir, f))
    }.sort_by { |f|
      f.sortkey
    }
    @entries.reverse!  if $reverse

    if @entries.empty?
      @entries = [EmptyItem.new("empty")]
    end
  rescue Errno::EACCES
    @entries = [EmptyItem.new("permission denied")]
  end

  def width
    [[MIN_COL_WIDTH, (@entries.map { |e| e.width }.max || 0)].max,
     active? ? MAX_ACTIVE_COL_WIDTH : MAX_COL_WIDTH].min +
      (active? ? 5 : 0)
  end

  def sel
    @entries[@cur]
  end

  def cursor(offset)
    @cur = [[@cur + offset, 0].max, @entries.size-1].min
  end

  def next
    @cur = (@cur+1) % @entries.size
  end

  def first
    @cur = 0
  end

  def last
    @cur = @entries.size-1
  end

  def select(name)
    @entries.each_with_index { |e, i|
      @cur = i
      return  if e.name == name
    }
    @cur = 0
  end

  def draw(x)
    max_y = Curses.lines - 5
    skiplines = [0, cur - max_y + 1].max
    
    @entries.each_with_index { |entry, j|
      next  if j < skiplines
      break  if j-skiplines > max_y
      
      Curses.setpos(j+2-skiplines, x)
      Curses.standout  if j == @cur
      Curses.attron(Curses::A_BOLD)  if entry.marked?
      Curses.addstr entry.format(width, active?)
      Curses.attroff(Curses::A_BOLD)  if entry.marked?
      Curses.standend  if j == @cur
    }
  end

  def leave
    prev_active = $active
    $active = $active.parent
    $columns.delete prev_active  unless prev_active == $active
  end
end

class Favorites < Directory
  def refresh
    @entries = FAVORITES.map { |path, label|
      FavoriteItem.new(File.expand_path(path), label) 
    }
  end
end

class EmptyItem
  def initialize(msg)
    @msg = msg
  end

  def width
    0
  end

  def format(width, detail)
    ls_l.ljust(width)
  end

  def activate
  end

  def marked?
    false
  end

  def preview
    ""
  end

  def name
    ""
  end

  def directory?
    false
  end

  def ls_l
    "-- #@msg --"
  end
end

class FileItem
  attr_reader :path, :name

  def initialize(path)
    @path = path

    refresh
  end

  def refresh
    @name = File.basename @path
    @lstat = File.lstat @path  rescue nil
    @stat = File.stat @path   rescue nil
    @stat ||= @lstat
  end

  def marked?
    $marked.include? @path
  end

  def format(width, detail)
    if @lstat.symlink?
      sigil = "@"
    elsif @stat.directory?
      sigil = "/"
    elsif @stat.executable?
      sigil = "*"
    elsif @stat.socket?
      sigil = "="
    elsif @stat.pipe?
      sigil = "|"
    else
      sigil = ""
    end
    
    if detail && !directory?
      trunc(@name+sigil, width-5).ljust(width - 5) + "%5s" % human(@stat.size)
    else
      trunc(@name+sigil, width).ljust(width)
    end
  end
  
  def trunc(str, width)
    if str.size > width
      str[0, 2*width/3] + "*" + str[-(width/3)..-1]
    else
      str
    end
  end

  def human(size)
    units = %w{B K M G T P E Z Y}
    until size < 1024
      units.shift
      size /= 1024.0
    end
    "%d%s" % [size, units.first]
  end

  def ls_l
    return "-- not found --"  unless @lstat
    "%s %d %s %s %s %s %s%s" %
      [modestring, @lstat.nlink, user, group, sizenode, mtime, @name, linkinfo]
  end

  # Inspired by busybox.
  def modestring
    mode = @lstat.mode

    buf = "0pcCd?bB-?l?s???"[(mode >> 12) & 0x0f, 1]
    buf << (mode & 00400 == 0 ? "-" : "r")
    buf << (mode & 00200 == 0 ? "-" : "w")
    buf << (mode & 04000 == 0 ? (mode & 00100 == 0 ? "-" : "x") :
                                (mode & 00100 == 0 ? "S" : "s"))
    buf << (mode & 00040 == 0 ? "-" : "r")
    buf << (mode & 00020 == 0 ? "-" : "w")
    buf << (mode & 02000 == 0 ? (mode & 00010 == 0 ? "-" : "x") :
                                (mode & 00010 == 0 ? "S" : "s"))
    buf << (mode & 00004 == 0 ? "-" : "r")
    buf << (mode & 00002 == 0 ? "-" : "w")
    buf << (mode & 01000 == 0 ? (mode & 00001 == 0 ? "-" : "x") :
                                (mode & 00001 == 0 ? "T" : "t"))
  end

  def user
    Etc.getpwuid(@lstat.uid).name
  end

  def group
    Etc.getgrgid(@lstat.gid).name
  end

  # Inspired by busybox.
  def mtime
    age = Time.now - @stat.mtime
    @lstat.mtime.strftime("%b %d " +
      (age > 60*60*24*365/2 || age < -15*60 ? " %Y" : "%H:%M"))
  end

  def sizenode
    if @lstat.blockdev? || @lstat.chardev?
      "%3d, %3d" % [@lstat.rdev>>8 & 0xff,
                  @lstat.rdev    & 0xff]
    else
      human(@lstat.size)
    end
  end

  def linkinfo
    if symlink?
      " -> #{File.readlink @path}"
    else
      ""
    end
  end

  def directory?
    @stat && @stat.directory?
  end

  def file?
    @stat && @stat.file?
  end

  def symlink?
    @lstat && @lstat.symlink?
  end

  def sortkey
    return []  unless @lstat
    
    case $sort
    when 1 # name
      [directory? ? 0 : 1, @name]
    when 2 # extension
      [directory? ? 0 : 1, @name.split('.').last]
    when 3 # size
      [directory? ? 0 : 1, @stat.size]
    when 4 # atime
      [@stat.atime]
    when 5 # ctime
      [@stat.ctime]
    when 6 # mtime
      [@stat.mtime]
    end
  end

  def width
    @name.size + 1
  end

  def activate
    if directory?
      prev_active = $active
      $columns.push($active = Directory.new(path))
      $active.parent = prev_active
    else
      Curses.close_screen
      system "less", path
      Curses.refresh
    end
  end

  def preview
    if directory?
      "Directory #@name\n\n#{Dir.entries(@path).size} files"
    elsif file?
      header = File.open(@path) { |f| f.read(1024) }
      header.tr!("^\n \041-\176", '.')
      header
    else
      "No preview defined for #@name."
    end
  rescue
    "Can't read #@name:\n#$!"
  end
end

class FavoriteItem < FileItem
  def initialize(path, label=nil)
    super path
    @label = label || @name
  end

  def format(width, detail)
    trunc(@label, width).ljust(width)    
  end
end

def cd(dir)
  d = "/"
  prev_columns = $columns

  $columns = [$active = Favorites.new("")]
  $active.parent = $active
  $active.select "/"
  $active.sel.activate

  dir.split('/').each { |part|
    next  if part.empty?
    $active.select part
    $active.sel.activate
  }

  if col = prev_columns.find { |c| Directory === c && c.dir == $active.dir }
    $active.cur = col.cur
  end

  $pwd = dir
end

class Sidebar
  def width
    SIDEBAR_MIN_WIDTH
  end

  def draw(x)
    # The sidebar may use the full width left over.
    width = Curses.cols - x - 1
    
    header = $active.sel.preview.to_s
    
    y = 2
    header.each_line { |l|
      Curses.setpos(y, x)
      Curses.addstr l[0..width]
      y += 1
    }
  end
end

def refresh
  $columns.each { |col| col.refresh }
end

def draw
  0.upto(Curses.cols) { |i|
    Curses.setpos(i,0)
    Curses.clrtoeol
  }

  Curses.setpos(0, 0)
  Curses.addstr $pwd

  max_x, max_y = Curses.cols, Curses.lines-5

  sel = $active.sel
  Curses.setpos(Curses.lines-2, 0)
  Curses.addstr "[" + $marked.join(" ") + "]"
  Curses.setpos(Curses.lines-1, 0)
  Curses.addstr "colfm - #$sort - #{sel.ls_l}"

  if $sidebar
    sidebar = Sidebar.new
    total = sidebar.width
  else
    total = 0
  end
  cols = 0
  $columns.reverse_each { |c|
    total += c.width+1
    break  if total > max_x
    cols += 1
  }
  skipcols = $columns.size - cols

  x = 0
  $columns.each_with_index { |col, c|
    next  if c < skipcols
    col.draw(x)
    x += col.width + 1
  }

  sidebar.draw(x)  if $sidebar
end

def rtrunc(str, width)
  if str.size > width
    "..." + str[-width..-1]
  else
    str
  end
end

def isearch
  str = ""
  c = nil
  orig = $active.cur
  
  loop {
    draw
    
    Curses.setpos(Curses.lines-1, 0)
    Curses.addstr "colfm - #$sort - #{c} I-Search: " << str
    Curses.clrtoeol
    Curses.refresh
    
    case c = Curses.getch
    when ?/
      if $active.sel.directory?
        $active.sel.activate  
        str = ""
        c = nil
        orig = $active.cur
      end
      
    when 040..0176
      str << c
    when 0177                   # delete
      if str.empty?
        $active.cur = orig
        break
      end
      str = str[0...-1]
    when 033, Curses::KEY_CTRL_C, Curses::KEY_CTRL_G
      $active.cur = orig
      break
    when Curses::KEY_CTRL_W
      str.gsub!(/\A(.*)\S*\z/, '\1')
    when Curses::KEY_CTRL_U
      str = ""
    else
      break
    end
    
    if str == ".."
      $active.leave
      str = ""
      c = nil
      orig = $active.cur
    end
    
    $active.cur = cur = orig
    looped = false
    begin
      until $active.sel.name =~ Regexp.new(str) || ($active.cur == cur && looped)
        $active.next
        looped = true
      end
    rescue RegexpError
    end
  }        
end

begin
  if ARGV.first && File.directory?(ARGV.first)
    cd ARGV.first
  else
    cd Dir.pwd
  end

  Curses.init_screen
  Curses.nonl
  Curses.cbreak
  Curses.noecho
  Curses.stdscr.keypad true

  loop {
    draw
    
    case Curses.getch
    when ?q
      break
    when ?.
      $dotfiles = !$dotfiles
      refresh
    when ?~
      $backup = !$backup
      refresh
    when ?h, Curses::KEY_LEFT
      $active.leave
    when ?j, Curses::KEY_DOWN
      $active.cursor 1
    when ?k, Curses::KEY_UP
      $active.cursor -1
    when ?J, Curses::KEY_NPAGE
      $active.cursor Curses.lines/2
    when ?K, Curses::KEY_PPAGE
      $active.cursor -Curses.lines/2
    when ?g, Curses::KEY_HOME
      $active.first
    when ?G, Curses::KEY_END
      $active.last
    when ?v
      $sidebar = !$sidebar
      refresh
    when ?S
      $reverse = !$reverse
      refresh
    when ?s
      $sort = $sort%6 + 1
      refresh
    when ?/
      isearch
      draw
      Curses.refresh
    when ?l, Curses::KEY_RIGHT, ?\r
      $active.sel.activate
    when ?C
      $marked.clear
    when ?m, ?\s
      sel = $active.sel.path
      if $marked.include? sel
        $marked -= [sel]
      else
        $marked << sel
      end
    end
  }

ensure
  Curses.close_screen
end
