#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require 'etc'
require 'pp'

=begin
TODO:
- find favorites from mounts etc.
- compressed files?
- tabbed interface
=end


require 'ffi'
module Setlocale
  extend FFI::Library
  ffi_lib('c')
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
  KEY_F1 = NCurses::KEY_F0+1
  KEY_F2 = NCurses::KEY_F0+2
  KEY_F3 = NCurses::KEY_F0+3
  KEY_F4 = NCurses::KEY_F0+4
  KEY_F5 = NCurses::KEY_F0+5
  KEY_F6 = NCurses::KEY_F0+6
  KEY_F7 = NCurses::KEY_F0+7
  KEY_F8 = NCurses::KEY_F0+8
  KEY_F9 = NCurses::KEY_F0+9
  KEY_F10 = NCurses::KEY_F0+10

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


$dotfiles = false
$backup = true
$sidebar = false
$selection = false

$columns = []
$tabs = []

$marked = []

MIN_COL_WIDTH = 8
MAX_COL_WIDTH = 20
MAX_ACTIVE_COL_WIDTH = 28
SIDEBAR_MIN_WIDTH = 20

FAVORITES = [["/", "/"],
             ["~", "~"],
             ["~/Desktop", "Desktop"]]

VIEWER = "less"

RCFILE = File.expand_path("~/.colfmrc")
SAVE_MARKED = File.expand_path("~/.colfmsel")
SAVE_DIR = File.expand_path("~/.colfmdir")

$sort = 1
$reverse = false

if File.directory?(File.expand_path("~/.avfs/#avfsstat"))
  $avfs = File.expand_path("~/.avfs")
end

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
    Dir.chdir @dir

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
    if File.directory?(d=File.join(dir, name))
      @entries << FileItem.new(d)
      self.last
    else
      @cur = 0
    end
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
    Etc.getpwuid(@lstat.uid).name  rescue @lstat.uid.to_s
  end

  def group
    Etc.getgrgid(@lstat.gid).name  rescue @lstat.gid.to_s
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
      $columns += [$active = Directory.new(path)]
      $active.parent = prev_active
    elsif $avfs && File.directory?(File.join($avfs, path + "#"))
      prev_active = $active
      $columns += [$active = Directory.new(File.join($avfs, path + "#"))]
      $active.parent = prev_active
    else
      Curses.endwin
      system VIEWER, path
      Curses.refresh
    end
  end

  def preview
    if directory?
      "Directory #@name\n\n#{Dir.entries(@path).size} files"
    elsif file?
      header = File.open(@path) { |f| f.read(1024) || "" }
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

  curwidth = [Curses.cols/2, $active.dir.size+1].min
  tabwidth = [((Curses.cols-curwidth) / ($tabs.size-1)  rescue 0), 0].max
  $tabs.each_with_index { |t, i|
    if i == $tabcur
      Curses.attron(Curses::A_BOLD)
      Curses.addstr rtrunc($active.dir + " ", curwidth)
      Curses.attroff(Curses::A_BOLD)
    else
      Curses.addstr rtrunc(t[1].dir + " ", tabwidth)
    end
  }

  max_x, max_y = Curses.cols, Curses.lines-5

  sel = $active.sel
  Curses.setpos(Curses.lines-2, 0)
  Curses.addstr "#{$marked.size} [" + $marked.join(" ") + "]"
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
    return "_"  if width < 4
    "..." + str[-width+3..-1]
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
    when 0177, Curses::KEY_BACKSPACE                   # delete
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

    when Curses::KEY_LEFT, Curses::KEY_DOWN, Curses::KEY_UP, :accept
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

def action(title, question, command, *args)
  switch [Selection.new(title)]
  refresh
  draw
  Curses.setpos(Curses.lines-1, 0)
  Curses.clrtoeol
  Curses.addstr "colfm - #$sort - #{question} (y/N) "
  Curses.refresh
  case Curses.getch
  when ?y
    system command, *args
  end
  switch_back
  refresh
end


abort "no tty"  unless STDIN.tty?

begin
  $tabs = []
  ARGV.replace ["."]  if ARGV.empty?
  ARGV.each { |arg|
    case arg
    when "-"
      cd File.read(SAVE_DIR)  rescue Dir.pwd
    when nil
      cd Dir.pwd
    else
      dir = File.expand_path(arg)
      if File.directory?(dir) ||
          $avfs && File.directory?(File.join($avfs, dir + "#"))
        cd dir
      else
        cd Dir.pwd
      end
    end
    $tabs << [$columns, $active]
  }

  $tabcur = 0
  $columns, $active = $tabs[$tabcur]

  $marked = File.read(SAVE_MARKED).split("\0")  rescue []  if SAVE_MARKED

  $stdscr = Curses.initscr
  Curses.nonl
  Curses.cbreak
  Curses.raw
  Curses.noecho
  Curses.keypad($stdscr, 1)
  Curses.meta($stdscr, 1)

  loop {
    draw

    case c = Curses.getch
    when Curses::KEY_CTRL_L, Curses::KEY_CTRL_R
      refresh
      Curses.clear
      draw
    when ?q, Curses::KEY_F10, Curses::KEY_CTRL_O
      break
    when ?., ?~
      $dotfiles = !$dotfiles  if c == ?.
      $backup = !$backup      if c == ?~
      names = $columns.map { |col| col.sel.name }
      refresh
      $columns.each_with_index { |col, i|
        col.first
        col.next
        while col.sel.name != names[i] && col.cur != 0
          col.next
        end
      }
    when ?h, Curses::KEY_LEFT
      $active.leave
    when ?j, Curses::KEY_DOWN
      $active.cursor 1
    when ?k, Curses::KEY_UP
      $active.cursor -1
    when ?l, Curses::KEY_RIGHT, ?\r, Curses::KEY_F3
      $active.sel.activate
    when ?J, Curses::KEY_NPAGE
      $active.cursor Curses.lines/2
    when ?K, Curses::KEY_PPAGE
      $active.cursor -Curses.lines/2
    when ?g, Curses::KEY_HOME
      $active.first
    when ?G, Curses::KEY_END
      $active.last
    when ?n
      if $active.sel.directory?
        $tabs[$tabcur] = [$columns, $active]
        $active.sel.activate
        $tabs.insert $tabcur+1, [$columns, $active]
        $columns, $active = $tabs[$tabcur]
      end
    when ?N
      $tabs.delete_at($tabcur)  if $tabs.size > 1
      $tabcur = $tabcur % $tabs.size
      $columns, $active = $tabs[$tabcur]
      refresh
    when ?t
      $tabs[$tabcur] = [$columns, $active]
      $tabcur = ($tabcur+1) % $tabs.size
      $columns, $active = $tabs[$tabcur]
    when ?T
      $tabs[$tabcur] = [$columns, $active]
      $tabcur = ($tabcur-1) % $tabs.size
      $columns, $active = $tabs[$tabcur]
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
    when ?/, Curses::KEY_CTRL_S
      isearch
      draw
      Curses.refresh
    when ?%
      iselect
      draw
      Curses.refresh
    when ?c
      $marked.clear
    when ?m, ?\s
      $active.sel.mark
    when Curses::KEY_F5, ?C
      target = $active.dir
      action "Copy these files?",
             "Copy these #{$marked.size} files to #{target}?",
             "cp", "-a", *($marked + [target])
    when Curses::KEY_F6, ?M
      target = $active.dir
      action "Move these files?",
             "Move these #{$marked.size} files to #{target}?",
             "mv", *($marked + [target])
    when Curses::KEY_F7, ?+
      readline("Create directory: ") { |c, str|
        case c
        when :accept
          system "mkdir", "-p", str
          break
        end
      }
      refresh
    when Curses::KEY_F8, ?X
      action "Delete these files?",
             "Delete these #{$marked.size} files recursively?",
             "rm", "-rf", *$marked
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

  File.open(SAVE_MARKED, "w") { |out| out << $marked.join("\0") }  if SAVE_MARKED
  File.open(SAVE_DIR, "w") { |out| out << Dir.pwd }  if SAVE_DIR

ensure
  Curses.endwin
end
