-- gpu_fifo16.vhd - GP0 input queue.
--
-- Full reports the physical depth and is used only to detect a genuinely lost
-- word (E9). FullLogical models the documented PS1 limit of 16 words and is
-- the one reported in GPUSTAT.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gpu_fifo16 is
   generic
   (
      SIZE          : integer := 512;
      LOGICAL_FULL  : integer := 16
   );
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;
      Din         : in  std_logic_vector(31 downto 0);
      Wr          : in  std_logic;
      Full        : out std_logic;
      FullLogical : out std_logic;
      AtMostOne   : out std_logic;
      CPUThrottle : out std_logic;
      Dout        : out std_logic_vector(31 downto 0);
      Rd          : in  std_logic;
      Empty       : out std_logic
   );
end entity;

architecture arch of gpu_fifo16 is
   function clog2(n : integer) return integer is
      variable r : integer := 0;
      variable v : integer := n - 1;
   begin
      while v > 0 loop r := r + 1; v := v / 2; end loop;
      if r = 0 then r := 1; end if;
      return r;
   end function;

   constant AW : integer := clog2(SIZE);

   type t_memory is array(0 to SIZE-1) of std_logic_vector(31 downto 0);
   signal memory : t_memory;
   signal wrptr  : unsigned(AW-1 downto 0) := (others => '0');
   signal rdptr  : unsigned(AW-1 downto 0) := (others => '0');
   signal count  : unsigned(AW downto 0) := (others => '0');
begin
   Full        <= '1' when count = to_unsigned(SIZE, count'length) else '0';
   FullLogical <= '1' when count >= to_unsigned(LOGICAL_FULL, count'length) else '0';
   AtMostOne   <= '1' when count <= to_unsigned(1, count'length) else '0';
   Empty       <= '1' when count = 0 else '0';

   CPUThrottle <= '1' when count >= to_unsigned(SIZE-4, count'length) else '0';

   process(clk)
      variable do_read  : boolean;
      variable do_write : boolean;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            wrptr <= (others => '0');
            rdptr <= (others => '0');
            count <= (others => '0');
         else
            do_read  := (Rd = '1' and count /= to_unsigned(0, count'length));
            do_write := (Wr = '1' and (count < to_unsigned(SIZE, count'length) or do_read));

            if do_write then
               memory(to_integer(wrptr)) <= Din;
               if SIZE = 2 ** AW then
                  wrptr <= wrptr + 1;
               elsif wrptr = to_unsigned(SIZE-1, AW) then
                  wrptr <= (others => '0');
               else
                  wrptr <= wrptr + 1;
               end if;
            end if;

            if do_read then
               Dout <= memory(to_integer(rdptr));
               if SIZE = 2 ** AW then
                  rdptr <= rdptr + 1;
               elsif rdptr = to_unsigned(SIZE-1, AW) then
                  rdptr <= (others => '0');
               else
                  rdptr <= rdptr + 1;
               end if;
            end if;

            if do_write and not do_read then
               count <= count + 1;
            elsif do_read and not do_write then
               count <= count - 1;
            end if;
         end if;
      end if;
   end process;
end architecture;
