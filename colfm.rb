# -*- coding: utf-8 -*-
require 'curses'
require 'pp'

=begin
TODO:
- parse ARGV
- pgup/pgdown
- isearching for paths
- more status info (size, owner etc.)
- sorting
- hide backup~, show .dotfiles
- select multiple files, and operate on them
- compressed files?
- a bar on the left that shows favorites and /
=end

$columns = []
$colwidth = []
$active = []

$pwd = ""

MIN_COL_WIDTH = 8
MAX_COL_WIDTH = 20
MAX_LAST_COL_WIDTH = 35

def cd(dir)
  d = "/"

  prev_active = $active.dup

  $columns = []
  $colwidth = []
  $active = []

  parts = (dir + "/*").split('/')[1..-1]
  parts.each_with_index { |part, j|
    entries = Dir.entries(d).delete_if { |f| f =~ /^\./ }.map { |f|
      [f, if File.directory?(d + "/" + f)
            "/"
          elsif File.executable?(d + "/" + f)
            "*"
          else
            ""
          end]
    }.sort_by { |f, t|
      [t == "/" ? 0 : 1, f]
    }

    entries.each_with_index { |(f, t), i|
      if f == part
        $active << i
      end
    }

    maxwidth = entries.map { |(f, t)| f.size }.max + 1

    $columns << entries
    $colwidth << [[MIN_COL_WIDTH, maxwidth].max,
                  j < parts.size-1 ? MAX_COL_WIDTH : MAX_LAST_COL_WIDTH].min
    d << "/" << part
  }

  if $columns.last.empty?
    $columns.last << ['', '<empty>']
  end

  $active << (prev_active[$columns.size - 1] || 0)

  $pwd = dir
end

def update_status
  $sel = $pwd + "/" + $columns[$active.size-1][$active.last][0]
end

def draw
  Curses.clear
  Curses.setpos(0, 0)
  Curses.addstr $pwd

  x = 0
  y = 2

  max_x, max_y = Curses.cols, Curses.lines-5

  update_status

  Curses.setpos(Curses.lines-1, 0)
  Curses.addstr "colfm - " << rtrunc($sel, 50)

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
  trunc(entry[0] + entry[1], width).ljust(width)
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

begin
  cd Dir.pwd

  Curses.init_screen
  Curses.nonl
  Curses.cbreak
  Curses.noecho

  loop {
    draw
    
    case Curses.getch.chr
    when "q"
      break
    when "h"
      cd($pwd.split("/")[0...-1].join("/"))
    when "j"
      $active[$active.size - 1] = [$active[$active.size - 1] + 1, $columns[$active.size - 1].size - 1].min
    when "k"
      $active[$active.size - 1] = [$active[$active.size - 1] - 1, 0].max
    when "l"
      sel = $columns[$active.size-1][$active.last]
      if sel[1] == "/"
        cd $sel
      else
        system "less", $sel
      end
    end
  }

ensure
  Curses.close_screen
end
