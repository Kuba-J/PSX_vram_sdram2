library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gpu_cpu2vram is
   port
   (
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      gpuLogicCe           : in  std_logic;
      reset                : in  std_logic;
      drawer_reset         : in  std_logic;

      DrawPixelsMask       : in  std_logic;
      SetMask              : in  std_logic;
      errorMASK            : out std_logic;

      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
      streamRequestFifo    : out std_logic := '0';
      done                 : out std_logic := '0';
      CmdDone              : out std_logic := '0';

      pipeline_busy        : in  std_logic;
      fifoOut_idle         : in  std_logic;
      requestVRAMEnable    : out std_logic;
      requestVRAMXPos      : out unsigned(9 downto 0);
      requestVRAMYPos      : out unsigned(8 downto 0);
      requestVRAMSize      : out unsigned(10 downto 0);
      requestVRAMSecond    : out std_logic;
      requestVRAMIdle      : in  std_logic;
      requestVRAMDone      : in  std_logic;

      vramMaskLineEna      : out std_logic;
      vramMaskLineAddr     : out unsigned(9 downto 0);
      vramMaskLineData     : in  std_logic_vector(15 downto 0);

      pixelStall           : in  std_logic;
      pixelColor           : out std_logic_vector(15 downto 0);
      pixelAddr            : out unsigned(19 downto 0);
      pixelWrite           : out std_logic
   );
end entity;

architecture arch of gpu_cpu2vram is
   type tState is
   (
      IDLE,
      REQUESTWORD2,
      REQUESTWORD3,
      WAITMASKDRAIN,
      READMASK,
      WAITMASK,
      PRIMEMASK,
      WRITING
   );
   signal state : tState := IDLE;
   signal readDonePending : std_logic := '0';

   signal copyDstX     : unsigned(9 downto 0);
   signal copyDstY     : unsigned(8 downto 0);
   signal copySizeX    : unsigned(10 downto 0);
   signal copySizeY    : unsigned(9 downto 0);

   signal x            : unsigned(10 downto 0);
   signal y            : unsigned(9 downto 0);

   signal half_valid   : std_logic := '0';
   signal half_data    : std_logic_vector(15 downto 0);

   signal streamWordValid : std_logic := '0';
   signal streamWord      : std_logic_vector(31 downto 0) := (others => '0');
   signal pixelIssue      : std_logic;
   signal streamNeedWord  : std_logic;
begin

   streamNeedWord <= '1' when (state = WRITING and pixelStall = '0' and
                                  fifo_Valid = '0' and streamWordValid = '0' and
                                  (half_valid = '0' or x + 1 < copySizeX or
                                   (DrawPixelsMask = '0' and y + 1 < copySizeY))) else '0';

   streamRequestFifo <= streamNeedWord;
   requestFifo <= '1' when (state = REQUESTWORD2 or state = REQUESTWORD3) else
                  streamNeedWord;

   pixelIssue <= '1' when (state = WRITING and ce = '1' and
                           gpuLogicCe = '1' and pixelStall = '0' and
                           (half_valid = '1' or streamWordValid = '1' or
                            fifo_Valid = '1')) else '0';

   requestVRAMEnable <= '1' when (state = READMASK) else '0';
   requestVRAMXPos   <= copyDstX when (state = READMASK) else (others => '0');
   requestVRAMYPos   <= resize(copyDstY + y(8 downto 0), 9) when (state = READMASK) else (others => '0');
   requestVRAMSize   <= copySizeX when (state = READMASK) else (others => '0');
   requestVRAMSecond <= '1' when state = READMASK else '0';

   vramMaskLineEna  <= '1' when (state = PRIMEMASK or state = WRITING) and DrawPixelsMask = '1' else '0';
   vramMaskLineAddr <= resize(copyDstX + x(9 downto 0) + 1, 10)
                       when (state = WRITING and pixelIssue = '1') else
                       resize(copyDstX + x(9 downto 0), 10)
                       when (state = PRIMEMASK or state = WRITING) else
                       (others => '0');

   process (clk2x)
      variable row : unsigned(8 downto 0);
      variable col : unsigned(9 downto 0);
      variable have_pixel : boolean;
      variable pixel_in   : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk2x) then

         if state /= WAITMASK then
            readDonePending <= '0';
         elsif requestVRAMDone = '1' then
            readDonePending <= '1';
         end if;

         if (state = WRITING and fifo_Valid = '1' and streamWordValid = '0') then
            streamWord      <= fifo_data;
            streamWordValid <= '1';
         end if;

         errorMASK <= '0';

         if reset = '1' then
            state      <= IDLE;
            half_valid <= '0';
            streamWordValid <= '0';
            readDonePending <= '0';

         elsif ce = '1' then
            pixelColor <= (others => '0');
            pixelAddr  <= (others => '0');
            pixelWrite <= '0';
            done       <= '0';
            CmdDone    <= '0';

            case state is
               when IDLE =>
                  half_valid       <= '0';
                  streamWordValid  <= '0';
                  if proc_idle = '1' and fifo_Valid = '1' and fifo_data(31 downto 29) = "101" then
                     state <= REQUESTWORD2;
                  end if;

               when REQUESTWORD2 =>
                  if fifo_Valid = '1' then
                     state    <= REQUESTWORD3;
                     copyDstX <= unsigned(fifo_data(9 downto 0));
                     copyDstY <= unsigned(fifo_data(24 downto 16));
                  end if;

               when REQUESTWORD3 =>
                  if fifo_Valid = '1' then
                     CmdDone   <= '1';
                     copySizeX <= '0' & unsigned(fifo_data(9 downto 0));
                     copySizeY <= '0' & unsigned(fifo_data(24 downto 16));
                     x         <= (others => '0');
                     y         <= (others => '0');
                     half_valid<= '0';
                     streamWordValid <= '0';
                     if unsigned(fifo_data(9 downto 0)) = 0 then copySizeX <= to_unsigned(16#400#, 11); end if;
                     if unsigned(fifo_data(24 downto 16)) = 0 then copySizeY <= to_unsigned(16#200#, 10); end if;
                     if DrawPixelsMask = '1' then
                        state <= WAITMASKDRAIN;
                     else
                        state <= WRITING;
                     end if;
                  end if;

               when WAITMASKDRAIN =>
                  if gpuLogicCe = '1' and pipeline_busy = '0' and fifoOut_idle = '1' then
                     state <= READMASK;
                  end if;

               when READMASK =>
                  if requestVRAMIdle = '1' then
                     state <= WAITMASK;
                  end if;

               when WAITMASK =>
                  if gpuLogicCe = '1' and
                     (readDonePending = '1' or requestVRAMDone = '1') then
                     readDonePending <= '0';
                     state <= PRIMEMASK;
                  end if;

               when PRIMEMASK =>
                  if gpuLogicCe = '1' then
                     state <= WRITING;
                  end if;

               when WRITING =>
                  if pixelIssue = '1' then
                     have_pixel := false;
                     pixel_in   := (others => '0');

                     if half_valid = '1' then
                        have_pixel := true;
                        pixel_in   := half_data;
                        half_valid <= '0';
                     elsif streamWordValid = '1' then
                        have_pixel := true;
                        pixel_in   := streamWord(15 downto 0);
                        half_data  <= streamWord(31 downto 16);
                        half_valid <= '1';
                        streamWordValid <= '0';
                     elsif fifo_Valid = '1' then
                        have_pixel := true;
                        pixel_in   := fifo_data(15 downto 0);
                        half_data  <= fifo_data(31 downto 16);
                        half_valid <= '1';
                        streamWordValid <= '0';
                     end if;

                     if have_pixel then
                        row := copyDstY + y(8 downto 0);
                        col := copyDstX + x(9 downto 0);

                        pixelAddr  <= row & col & '0';
                        pixelColor <= pixel_in;
                        if SetMask = '1' then
                           pixelColor(15) <= '1';
                        end if;

                        if DrawPixelsMask = '0' or vramMaskLineData(15) = '0' then
                           pixelWrite <= '1';
                        end if;

                        if x + 1 < copySizeX then
                           x <= x + 1;
                        else
                           x <= (others => '0');
                           if y + 1 < copySizeY then
                              y <= y + 1;
                              if DrawPixelsMask = '1' then
                                 state <= READMASK;
                              end if;
                           else
                              state <= IDLE;
                              done  <= '1';
                              half_valid <= '0';
                              streamWordValid <= '0';
                           end if;
                        end if;
                     end if;
                  end if;
            end case;

            if drawer_reset = '1' then
               state      <= IDLE;
               half_valid <= '0';
               streamWordValid <= '0';
               if state /= IDLE then
                  done <= '1';
               end if;
            end if;
         end if;
      end if;
   end process;
end architecture;
