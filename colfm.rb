# -*- coding: utf-8 -*-
require 'curses'
require 'pp'

=begin
TODO:
- isearching for paths
- select multiple files, and operate on them
- compressed files?
- a bar on the left that shows favorites and /
=end

$columns = []
$colwidth = []
$active = []

$dotfiles = false
$backup = true

$pwd = ""

MIN_COL_WIDTH = 8
MAX_COL_WIDTH = 20
MAX_LAST_COL_WIDTH = 35

$sort = 1
$reverse = false
def sortkey(f,l,s)
  return []  unless l

  case $sort
  when 1 # name
    [s.directory? ? 0 : 1, f]
  when 2 # extension
    [s.directory? ? 0 : 1, f.split('.').last]
  when 3 # size
    [s.size]
  when 4 # atime
    [s.atime]
  when 5 # ctime
    [s.ctime]
  when 6 # mtime
    [s.mtime]
  end
end

def cd(dir)
  d = "/"

  prev_active = $active.dup

  $columns = []
  $colwidth = []
  $active = []

  parts = (dir + "/*").split('/')[1..-1]
  parts.each_with_index { |part, j|
    entries = Dir.entries(d).
    delete_if { |f| f =~ /^\./ && !$dotfiles }.
    delete_if { |f| f =~ /~\z/ && !$backup }.
    map { |f|
      [f, File.lstat(d + "/" + f), File.stat(d + "/" + f)]
    }.sort_by { |f, l, s|
      sortkey(f, l, s)
    }
    entries = entries.reverse  if $reverse

    entries.each_with_index { |(f, l, s), i|
      if f == part
        $active << i
      end
    }

    maxwidth = (entries.map { |(f, l, s)| f.size }.max || 0) + 1

    $columns << entries
    $colwidth << [[MIN_COL_WIDTH, maxwidth].max,
                  j < parts.size-1 ? MAX_COL_WIDTH : MAX_LAST_COL_WIDTH].min
    d << "/" << part
  }

  if $columns.last.empty?
    $columns.last << ['', nil]
  end

  $active << (prev_active[$columns.size - 1] || 0)

  $pwd = dir
end

def refresh
  cd($pwd)
end

def update_sel
  $sel = $pwd + "/" + $columns[$active.size-1][$active.last][0]
end

def draw
  Curses.clear
  Curses.setpos(0, 0)
  Curses.addstr $pwd

  x = 0
  y = 2

  max_x, max_y = Curses.cols, Curses.lines-5

  update_sel

  Curses.setpos(Curses.lines-1, 0)
  Curses.addstr "colfm - #$sort " << `ls -ldhi #$sel`

  total = 0
  cols = 0
  $colwidth.reverse_each { |w|
    total += w+1
    break  if total > max_x
    cols += 1
  }
  skipcols = $columns.size - cols

  skiplines = [0, $active.last - max_y + 1].max

  $active.each_with_index { |act, i|
    next  if i < skipcols

    $columns[i].each_with_index { |entry, j|
      next  if j < skiplines
      break  if j-skiplines > max_y

      Curses.setpos(j+y-skiplines, x)
      Curses.standout  if j == act
      Curses.addstr fmt(entry, $colwidth[i])
      Curses.standend  if j == act
    }
    x += $colwidth[i] + 1
  }
end

def fmt(entry, width)
  file, lstat, stat = entry
  return "-- empty --".ljust(width)  if lstat.nil?

  if lstat.symlink?
    sigil = "@"
  elsif stat.directory?
    sigil = "/"
  elsif stat.socket?
    sigil = "="
  elsif stat.pipe?
    sigil = "|"
  else
    sigil = ""
  end
  trunc(file+sigil, width).ljust(width)
end

def trunc(str, width)
  if str.size > width
    str[0, 2*width/3] + "*" + str[-(width/3)..-1]
  else
    str
  end
end

def rtrunc(str, width)
  if str.size > width
    "..." + str[-width..-1]
  else
    str
  end
end

def cursor(offset)
  a = $active.last
  $active[$active.size-1] = [[a + offset, 0].max, $columns[$active.size - 1].size - 1].min
end

begin
  if File.directory?(ARGV.first)
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
      cd($pwd.split("/")[0...-1].join("/"))
    when ?j, Curses::KEY_DOWN
      cursor 1
    when ?k, Curses::KEY_UP
      cursor -1
    when ?J, Curses::KEY_NPAGE
      cursor Curses.lines/2
    when ?K, Curses::KEY_PPAGE
      cursor -Curses.lines/2
    when ?g, Curses::KEY_HOME
      $active[$active.size-1] = 0
    when ?G, Curses::KEY_END
      $active[$active.size-1] = $columns[$active.size-1].size-1
    when ?S
      $reverse = !$reverse
      refresh
    when ?s
      $sort = $sort%6 + 1
      refresh
    when ?l, Curses::KEY_RIGHT     
      sel = $columns[$active.size-1][$active.last]
      if sel[2] && sel[2].directory?
        cd $sel
      else
        Curses.close_screen
        system "less", $sel
        Curses.refresh
      end
    end
  }

ensure
  Curses.close_screen
end
