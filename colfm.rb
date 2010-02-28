require 'curses'

$columns = [
           %w{dir1/ dir2/ dir3/ file1 file2 file3},
           %w{dir1/ dir2/ dir3/ file1 file2 file3},
           %w{dir1/ dir2/ dir3/ file1 file2 file3},
          ]

$active = [0, 0, 2]

COL_WIDTH = 10

def draw
  Curses.clear
  Curses.setpos(0, 0)
  $active.each_with_index { |act, i|
    $columns[i].each_with_index { |entry, j|
      Curses.setpos(j, i*COL_WIDTH)
      Curses.standout  if j == act
      Curses.addstr entry.ljust(COL_WIDTH-1)
      Curses.standend  if j == act
    }
  }
end

begin
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
      $active.pop
    when "j"
      $active[$active.size - 1] += 1
    when "k"
      $active[$active.size - 1] -= 1
    when "l"
      $active.push 0  if $active.size < $columns.size
    end
  }

ensure
  Curses.close_screen
end
