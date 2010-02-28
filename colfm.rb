require 'curses'

$columns = Dir.pwd.split('/')

$active = [0] * $columns.size

$pwd = ""

COL_WIDTH = 10

def cd(dir)
  d = "/"

  prev_active = $active.dup

  $columns = []
  $active = []

  (dir + "/*").split('/')[1..-1].each { |part|
    $columns << Dir.entries(d).delete_if { |f| f =~ /^\./ }.map { |f|
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

    $columns.last.each_with_index { |(f, t), i|
      if f == part
        $active << i
      end
    }

    d << "/" << part
  }

  if $columns.last.empty?
    $columns.last << ['', '<empty>']
  end

  $active << (prev_active[$columns.size - 1] || 0)

  $pwd = dir
end

def draw
  Curses.clear
  Curses.setpos(0, 0)
  Curses.addstr $pwd

  $active.each_with_index { |act, i|
    $columns[i].each_with_index { |entry, j|
      Curses.setpos(j+2, i*COL_WIDTH)
      Curses.standout  if j == act
      Curses.addstr fmt(entry)
      Curses.standend  if j == act
    }
  }
end

def fmt(entry)
  (entry[0][0,COL_WIDTH-2] + entry[1]).ljust(COL_WIDTH-1)
end

begin
  Curses.init_screen
  Curses.nonl
  Curses.cbreak
  Curses.noecho

  cd Dir.pwd

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
        cd(($pwd.split("/") << sel[0]).join("/"))
      else
        system "less", $pwd + "/" + sel[0]
      end
    end
  }

ensure
  Curses.close_screen
end
