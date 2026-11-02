library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gpu_vram2vram is
   port
   (
      clk2x                : in  std_logic;
      clk2xIndex           : in  std_logic;
      ce                   : in  std_logic;
      gpuLogicCe           : in  std_logic;
      isPal                : in  std_logic;
      reset                : in  std_logic;

      DrawPixelsMask       : in  std_logic;
      SetMask              : in  std_logic;

      REPRODUCIBLEGPUTIMING: in  std_logic;

      proc_idle            : in  std_logic;
      fifo_Valid           : in  std_logic;
      fifo_data            : in  std_logic_vector(31 downto 0);
      requestFifo          : out std_logic := '0';
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

      vramLineEna          : out std_logic;
      vramLineAddr         : out unsigned(9 downto 0);
      vramLineData         : in  std_logic_vector(15 downto 0);
      vramLine2Ena         : out std_logic;
      vramLine2Addr        : out unsigned(9 downto 0);
      vramLineData2        : in  std_logic_vector(15 downto 0);

      pixelEmpty           : in  std_logic;
      pixelStall           : in  std_logic;
      pixelColor           : out std_logic_vector(15 downto 0);
      pixelAddr            : out unsigned(19 downto 0);
      pixelWrite           : out std_logic
   );
end entity;

architecture arch of gpu_vram2vram is
   type tState is
   (
      IDLE,
      REQUESTWORD2,
      REQUESTWORD3,
      REQUESTWORD4,
      REQUESTFIRST,
      READSRC,
      WAITSRC,
      WAITIMING,
      READDEST,
      WAITDEST,
      READFIRST,
      WRITING,
      PACELINE
   );
   signal state : tState := IDLE;
   signal srcReadDonePending : std_logic := '0';
   signal dstReadDonePending : std_logic := '0';

   constant PACE_CREDIT    : integer := 1000;
   constant PACE_COST_NTSC : integer := 2123;
   constant PACE_COST_PAL  : integer := 2103;

   signal paceAcc      : signed(23 downto 0) := (others => '0');
   signal paceLast     : std_logic := '0';

   signal srcX         : unsigned(9 downto 0);
   signal srcY         : unsigned(8 downto 0);
   signal dstX         : unsigned(9 downto 0);
   signal dstY         : unsigned(8 downto 0);
   signal widt         : unsigned(10 downto 0);
   signal heig         : unsigned(9 downto 0);

   signal dir          : std_logic;
   signal xSrc         : unsigned(9 downto 0);
   signal xDst         : unsigned(9 downto 0);
   signal xCnt         : unsigned(10 downto 0);
   signal yCnt         : unsigned(9 downto 0);
   signal drawTiming   : unsigned(6 downto 0);
begin
   requestFifo <= '1' when (state = REQUESTWORD2 or state = REQUESTWORD3 or state = REQUESTWORD4) else '0';

   requestVRAMEnable <= '1' when (state = READSRC or state = READDEST) else '0';
   requestVRAMXPos   <= srcX when (state = READSRC) else
                       dstX when (state = READDEST) else (others => '0');
   requestVRAMYPos   <= srcY when (state = READSRC) else
                       dstY when (state = READDEST) else (others => '0');
   requestVRAMSize   <= widt when (state = READSRC or state = READDEST) else (others => '0');
   requestVRAMSecond <= '1' when state = READDEST else '0';

   vramLineEna   <= '1' when (state = WRITING or state = READFIRST) else '0';
   vramLineAddr  <= xSrc when (state = WRITING or state = READFIRST) else (others => '0');
   vramLine2Ena  <= '1' when (state = WRITING or state = READFIRST) and DrawPixelsMask = '1' else '0';
   vramLine2Addr <= xDst when state = READFIRST else
                    (xDst - 1) when (state = WRITING and dir = '1') else
                    (xDst + 1) when state = WRITING else
                    (others => '0');

   process (clk2x)
      variable srcXCheck : unsigned(9 downto 0);
      variable dstXCheck : unsigned(9 downto 0);
      variable paceDelta : signed(12 downto 0);
   begin
      if rising_edge(clk2x) then
         if state /= WAITSRC then
            srcReadDonePending <= '0';
         elsif requestVRAMDone = '1' then
            srcReadDonePending <= '1';
         end if;
         if state /= WAITDEST then
            dstReadDonePending <= '0';
         elsif requestVRAMDone = '1' then
            dstReadDonePending <= '1';
         end if;

         if reset = '1' then
            state   <= IDLE;
            paceAcc <= (others => '0');
            srcReadDonePending <= '0';
            dstReadDonePending <= '0';
         elsif ce = '1' then
            if (state = IDLE or state = REQUESTWORD2 or state = REQUESTWORD3 or
                state = REQUESTWORD4 or state = REQUESTFIRST) then
               paceAcc <= (others => '0');
            elsif state = WRITING then
               if isPal = '1' then
                  if gpuLogicCe = '1' then
                     paceDelta := to_signed(PACE_CREDIT - PACE_COST_PAL, 13);
                  else
                     paceDelta := to_signed(-PACE_COST_PAL, 13);
                  end if;
               else
                  if gpuLogicCe = '1' then
                     paceDelta := to_signed(PACE_CREDIT - PACE_COST_NTSC, 13);
                  else
                     paceDelta := to_signed(-PACE_COST_NTSC, 13);
                  end if;
               end if;
               paceAcc <= paceAcc + resize(paceDelta, paceAcc'length);
            elsif gpuLogicCe = '1' then
               paceAcc <= paceAcc + to_signed(PACE_CREDIT, 24);
            end if;

            pixelColor <= (others => '0');
            pixelAddr  <= (others => '0');
            pixelWrite <= '0';
            done       <= '0';
            CmdDone    <= '0';

            if state /= IDLE and gpuLogicCe = '1' then
               drawTiming <= drawTiming + 1;
            end if;

            case state is
               when IDLE =>
                  yCnt <= (others => '0');
                  if proc_idle = '1' and fifo_Valid = '1' and fifo_data(31 downto 29) = "100" then
                     state <= REQUESTWORD2;
                  end if;

               when REQUESTWORD2 =>
                  if fifo_Valid = '1' then
                     state <= REQUESTWORD3;
                     srcX  <= unsigned(fifo_data(9 downto 0));
                     srcY  <= unsigned(fifo_data(24 downto 16));
                  end if;

               when REQUESTWORD3 =>
                  if fifo_Valid = '1' then
                     state <= REQUESTWORD4;
                     dstX  <= unsigned(fifo_data(9 downto 0));
                     dstY  <= unsigned(fifo_data(24 downto 16));
                  end if;

               when REQUESTWORD4 =>
                  if fifo_Valid = '1' then
                     srcXCheck := srcX + unsigned(fifo_data(9 downto 0)) - 1;
                     dstXCheck := dstX + unsigned(fifo_data(9 downto 0)) - 1;
                     if srcX < dstX or srcXCheck < dstXCheck then
                        dir <= '1';
                     else
                        dir <= '0';
                     end if;

                     CmdDone <= '1';
                     state   <= REQUESTFIRST;
                     widt    <= '0' & unsigned(fifo_data(9 downto 0));
                     heig    <= '0' & unsigned(fifo_data(24 downto 16));
                     if unsigned(fifo_data(9 downto 0)) = 0 then widt <= to_unsigned(16#400#, 11); end if;
                     if unsigned(fifo_data(24 downto 16)) = 0 then heig <= to_unsigned(16#200#, 10); end if;
                  end if;

               when REQUESTFIRST =>
                  if gpuLogicCe = '1' and pipeline_busy = '0' and fifoOut_idle = '1' then
                     state <= READSRC;
                  end if;

               when READSRC =>
                  if dir = '1' then
                     xSrc <= resize(srcX + widt - 1, 10);
                     xDst <= resize(dstX + widt - 1, 10);
                  else
                     xSrc <= srcX;
                     xDst <= dstX;
                  end if;
                  xCnt <= (others => '0');
                  if requestVRAMIdle = '1' then
                     state      <= WAITSRC;
                     drawTiming <= (others => '0');
                  end if;

               when WAITSRC =>
                  if gpuLogicCe = '1' and
                     (srcReadDonePending = '1' or requestVRAMDone = '1') then
                     srcReadDonePending <= '0';
                     if REPRODUCIBLEGPUTIMING = '1' then
                        state <= WAITIMING;
                     elsif DrawPixelsMask = '1' then
                        state <= READDEST;
                     else
                        state <= READFIRST;
                     end if;
                  end if;

               when WAITIMING =>
                  if gpuLogicCe = '1' and drawTiming >= 80 then
                     if DrawPixelsMask = '1' then
                        state <= READDEST;
                     else
                        state <= READFIRST;
                     end if;
                  end if;

               when READDEST =>
                  if requestVRAMIdle = '1' then
                     state <= WAITDEST;
                  end if;

               when WAITDEST =>
                  if gpuLogicCe = '1' and
                     (dstReadDonePending = '1' or requestVRAMDone = '1') then
                     dstReadDonePending <= '0';
                     state <= READFIRST;
                  end if;

               when READFIRST =>
                  if gpuLogicCe = '1' and pixelEmpty = '1' then
                     state <= WRITING;
                     if dir = '1' then
                        xSrc <= xSrc - 1;
                     else
                        xSrc <= xSrc + 1;
                     end if;
                  end if;

               when WRITING =>
                  if DrawPixelsMask = '0' or vramLineData2(15) = '0' then
                     pixelWrite <= '1';
                  end if;

                  pixelAddr  <= dstY & xDst & '0';
                  pixelColor <= vramLineData;
                  if SetMask = '1' then
                     pixelColor(15) <= '1';
                  end if;

                  if dir = '1' then
                     xSrc <= xSrc - 1;
                     xDst <= xDst - 1;
                  else
                     xSrc <= xSrc + 1;
                     xDst <= xDst + 1;
                  end if;

                  xCnt <= xCnt + 1;
                  if xCnt + 1 = widt then
                     srcY <= srcY + 1;
                     dstY <= dstY + 1;
                     yCnt <= yCnt + 1;
                     if yCnt + 1 = heig then
                        paceLast <= '1';
                     else
                        paceLast <= '0';
                     end if;
                     state <= PACELINE;
                  end if;

               when PACELINE =>
                  if gpuLogicCe = '1' and paceAcc >= 0 then
                     if paceLast = '1' then
                        state <= IDLE;
                        done  <= '1';
                     else
                        state <= READSRC;
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;
end architecture;
