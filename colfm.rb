# -*- coding: utf-8 -*-
require 'etc'
require 'pp'

require 'ffi'
module Setlocale
  extend FFI::Library
  LIB_HANDLE = ffi_lib('c').first
  LC_ALL = 6
  attach_function :setlocale, [:int, :string], :uint
end
Setlocale.setlocale(Setlocale::LC_ALL, "")

ENV["RUBY_FFI_NCURSES_LIB"] = "ncursesw"
require 'ffi-ncurses'
require 'ffi-ncurses/keydefs'
('A'..'Z').each { |c| NCurses.const_set "KEY_CTRL_#{c}", c[0]-?A+1 }

Curses = NCurses
Curses.extend FFI::NCurses

module Curses
  A_BOLD = FFI::NCurses::A_BOLD

  def self.cols
    getmaxx($stdscr)
  end

  def self.lines
    getmaxy($stdscr)
  end

  def self.setpos(y, x)
    move(y, x)
  end

  def addstr(s)
    waddnstr($stdscr, s, s.size)
  end
end

=begin
TODO:
- select multiple files, and operate on them
- find favorites from mounts etc.
- compressed files?
- bring selected directory/files back to shell
- tabbed interface
=end

$dotfiles = false
$backup = true
$sidebar = false
$selection = false

$columns = []

$marked = []

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

class Selection < Directory
  def refresh
    @entries = $marked.map { |path|
      FavoriteItem.new(File.expand_path(path), File.expand_path(path)) 
    }
    if @entries.empty?
      @entries = [EmptyItem.new("empty")]
    end
  end

  def width
    Curses.cols-1
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

  def mark
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

  def mark
    if $marked.include? path
      $marked -= [path]
    else
      $marked << path  
    end
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
      str[0, 2*width/3] + "…" + str[-(width/3)..-1]
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
      Curses.endwin
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

def switch(columns, active=columns.last)
  $prev_active,  $active  = $active,  active
  $prev_columns, $columns = $columns, columns
  $prev_sidebar, $sidebar = $sidebar, false
  $active.parent ||= $active
end

def switch_back
  $active = $prev_active
  $columns = $prev_columns
  $sidebar = $prev_sidebar
end

def cd(dir)
  d = "/"
  prev_columns = $columns

  $columns = [$active = Favorites.new("Favorites")]
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
end

class Sidebar
  def width
    SIDEBAR_MIN_WIDTH
  end

  def draw(x)
    # The sidebar may use the full width left over.
    width = Curses.cols - x - 1
    max_y = Curses.lines - 3
    
    header = $active.sel.preview.to_s
    
    y = 2
    header.each_line { |l|
      break  if y > max_y
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
  Curses.erase

  Curses.setpos(0, 0)
  Curses.addstr $active.dir

  max_x, max_y = Curses.cols, Curses.lines-5

  sel = $active.sel
  Curses.setpos(Curses.lines-2, 0)
  Curses.addstr "[" + $marked.join(" ") + "]"
  Curses.setpos(Curses.lines-1, 0)
  Curses.addstr "colfm - #$sort - #{sel ? sel.ls_l : ""}"

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

def readline(prompt)
  str = ""
  c = nil

  loop {
    draw

    Curses.setpos(Curses.lines-1, 0)
    Curses.addstr "colfm - #$sort - #{prompt}" << str
    Curses.clrtoeol
    Curses.refresh

    case c = Curses.getch      
    when 040..0176
      str << c
    when 0177                   # delete
      if str.empty?
        yield :cancel, str
        break
      end
      str = str[0...-1]
    when 033, Curses::KEY_CTRL_C, Curses::KEY_CTRL_G
      c = :cancel
    when Curses::KEY_CTRL_W
      str.gsub!(/\A(.*)\S*\z/, '\1')
    when Curses::KEY_CTRL_U
      str = ""
    when ?\r
      yield :accept, str
    end

    yield c, str
  }

  str
end

def isearch
  orig = $active.cur

  readline("I-search: ") { |c, str|
    case c
    when Curses::KEY_LEFT
      $active.leave

    when ?/, Curses::KEY_RIGHT
      if $active.sel.directory?
        $active.sel.activate  
        str.replace ""
        orig = $active.cur
      end

    when :cancel
      $active.cur = orig
      break

    when ?\r
      break

    end
    
    if str == ".."
      $active.leave
      str.replace ""
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

def iselect
  prev_marked = $marked.dup

  readline("I-select: ") { |c, str|
    case c
    when :cancel
      $marked = prev_marked
      break
    when :accept
      break
    end

    next  if str.empty?

    orig = $active.cur
    $active.next

    begin
      $marked.clear
      until $active.cur == orig
        $active.sel.mark  if $active.sel.name =~ Regexp.new(str)
        $active.next
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

  $stdscr = Curses.initscr
  Curses.nonl
  Curses.cbreak
  Curses.noecho
  Curses.keypad($stdscr, 1)
  Curses.meta($stdscr, 1)

  loop {
    draw
    
    case Curses.getch
    when Curses::KEY_CTRL_L, Curses::KEY_CTRL_R
      refresh
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
    when ?l, Curses::KEY_RIGHT, ?\r
      $active.sel.activate
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
    when ?V
      $selection = !$selection
      if $selection
        switch [Selection.new('Selection')]
      else
        switch_back
      end
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
    when ?%
      iselect
      draw
      Curses.refresh
    when ?C
      $marked.clear
    when ?m, ?\s
      $active.sel.mark
    when ?!
      readline("Shell command: ") { |c, str|
        case c
        when ?\t
          str << $active.sel.name << " "
        when Curses::KEY_BTAB
          str << $marked.join(" ")
        when Curses::KEY_LEFT
          $active.leave
        when Curses::KEY_DOWN
          $active.cursor 1
        when Curses::KEY_UP
          $active.cursor -1
        when Curses::KEY_RIGHT
          $active.sel.activate
        when :accept
          Curses.endwin
          if $active.kind_of? Directory
            Dir.chdir $active.dir
          end
          system str
          print "\n-- Shell command finished with #$? --"
          STDOUT.flush
          gets
          Curses.refresh
          break
        when :cancel
          break
        end
      }

    end
  }

ensure
  Curses.endwin
end
