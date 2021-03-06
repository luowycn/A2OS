(**
	AUTHOR: Alexey Morozov, Timothee Martiel
	PURPOSE: driver implementation for Xilinx Zynq UART PS controller
*)

MODULE PsUart;

IMPORT SYSTEM, PsUartMin, PsUartInterrupts, Trace;

CONST
	(** Receive errors - compatible with A2 Serials *)
	OverrunError* = 10;
	ParityError* = 11;
	FramingError* = 12;
	BreakInterrupt* = 13;

	DefaultRxBufSize* = 4096;
	DefaultTxBufSize* = 4096;

	ReceiveTimeoutInUs* = 500; (** Receive timeout in microseconds *)

	(* RX data interrupts *)
	RxDataInterrupts = {PsUartMin.XUARTPS_IXR_TOUT , PsUartMin.XUARTPS_IXR_RXFULL , PsUartMin.XUARTPS_IXR_RXOVR};

	(* RX error interrupts *)
	RxErrorInterrupts = {PsUartMin.XUARTPS_IXR_PARITY , PsUartMin.XUARTPS_IXR_FRAMING , PsUartMin.XUARTPS_IXR_OVER};

	RxInterrupts = RxDataInterrupts + RxErrorInterrupts;

TYPE

	UartId* = PsUartMin.UartId;
	ClockFrequency* = PsUartMin.ClockFrequency;

	UartController* = POINTER TO RECORD
		id-: UartId; (** UART controller ID *)
		regs-: PsUartMin.UartRegisters; (** controller registers *)
		inputClock-: ClockFrequency; (** controller input clock in Hz *)
		bps-, data-, parity-, stop-: LONGINT; (** current parameter values *)

		open-: BOOLEAN; (** TRUE if the controller is open *)

		rxBuf: POINTER TO ARRAY OF CHAR; (* receive (RX) circular buffer *)
		rxBufRdPos, rxBufWrPos: SIZE; (* RX buffer read and write positions *)

		errors: SET32;
	END;

VAR
	uarts: ARRAY 2 OF UartController;

	(* Disable all UART interrupts *)
	PROCEDURE DisableInterrupts(regs: PsUartMin.UartRegisters);
	BEGIN
		regs.idr := PsUartMin.XUARTPS_IXR_MASK;
	END DisableInterrupts;

	PROCEDURE IntrHandler(param: ANY);
	VAR
		uart: UartController;
		intrStatus: SET32;
	BEGIN
		uart := param(UartController);
		intrStatus := uart.regs.imr * uart.regs.isr;
		uart.regs.isr := intrStatus; (* clear the interrupt *)

		IF intrStatus * RxInterrupts # {} THEN
			IntrHandlerRx(uart,intrStatus);
		END;
	END IntrHandler;

	PROCEDURE IntrHandlerRx(uart: UartController; intrStatus: SET32);
	VAR
		bufWrPos: SIZE;
	BEGIN

		IF intrStatus * RxErrorInterrupts # {} THEN
			IF PsUartMin.XUARTPS_IXR_OVER IN intrStatus THEN
				INCL(uart.errors,OverrunError);
				Trace.String("---rx overrun(1)---: intrStatus="); Trace.Set(intrStatus); Trace.Ln;
				RETURN;
			END;
		END;

		bufWrPos := uart.rxBufWrPos;

		WHILE ~(PsUartMin.XUARTPS_SR_RXEMPTY IN uart.regs.sr) DO

			uart.rxBuf[bufWrPos] := CHR(uart.regs.fifo);
			INC(bufWrPos);
			IF bufWrPos = LEN(uart.rxBuf) THEN
				bufWrPos := 0;
			END;

			IF bufWrPos = uart.rxBufRdPos THEN
				INCL(uart.errors,OverrunError);
				Trace.String("---rx overrun(2)---: intrStatus="); Trace.Set(intrStatus); Trace.Ln;
				RETURN;
			END;
		END;

		uart.rxBufWrPos := bufWrPos;
	END IntrHandlerRx;

	(*
		Returns TRUE if a cyclic buffer is full
	*)
	PROCEDURE BufIsFull(bufWrPos, bufRdPos, bufSize: SIZE): BOOLEAN;
	BEGIN
		IF bufWrPos # (bufSize-1) THEN
			RETURN bufRdPos = (bufWrPos+1);
		ELSE
			RETURN bufRdPos = 0;
		END;
	END BufIsFull;

	(**
		Install a UART controller present in the system

		uart: ID (0-based index) of the UART controller to install
		base: controller base address
		inputClock: controller input clock in Hz
		res: returned error code, 0 in case of success
	*)
	PROCEDURE Install* (uart: UartId; base: ADDRESS; inputClock: ClockFrequency; VAR res: WORD);
	VAR ctl: UartController;
	BEGIN
		PsUartMin.Install(uart, base, inputClock, res);
		IF res # 0 THEN RETURN; END;

		NEW(ctl);
		uarts[uart] := ctl;

		ctl.id := uart;
		ctl.regs := PsUartMin.GetUart(uart);
		ctl.inputClock := inputClock;
		ctl.open := FALSE;
		ctl.bps := PsUartMin.DefaultBPS;
		ctl.data := PsUartMin.DefaultDataBits;
		ctl.parity := PsUartMin.DefaultParity;
		ctl.stop := PsUartMin.DefaultStop;

		NEW(ctl.rxBuf,DefaultRxBufSize);

		ASSERT(PsUartInterrupts.InstallInterruptHandler(uart,IntrHandler,ctl));
	END Install;

	(**
		Get UART controller with a given ID

		uart: UART controller ID

		Returns NIL in case if no controller with given ID has been installed
	*)
	PROCEDURE GetUart*(uart: UartId): UartController;
	BEGIN
		IF (uart >= 0) & (uart < LEN(uarts)) THEN
			RETURN uarts[uart];
		ELSE RETURN NIL;
		END;
	END GetUart;

	(**
		Open a UART controller

		uart: UART controller
		bps: baudrate
		data: number of data bits
		parity: parity control
		stop: number of stop bits
		res: returned error code, 0 in case of success
	*)
	PROCEDURE Open*(uart: UartController; bps, data, parity, stop: LONGINT; VAR res: WORD);
	VAR n: SIZE;
	BEGIN
		IF uart.open THEN res := PsUartMin.PortInUse; RETURN; END;

		PsUartMin.Reset(uart.regs);

		IF ~PsUartMin.SetBps(uart.regs, bps, res) OR
			~PsUartMin.SetDataBits(uart.regs, data, res) OR
			~PsUartMin.SetParity(uart.regs, parity, res) OR
			~PsUartMin.SetStopBits(uart.regs, stop, res) THEN  RETURN;
		END;

		uart.bps := bps;
		uart.data := data;
		uart.parity := parity;
		uart.stop := stop;

		uart.rxBufWrPos := 0;
		uart.rxBufRdPos := 0;

		(* configure receive timeout to be as close as possible to ReceiveTimeoutInUs *)
		n := ENTIER((ReceiveTimeoutInUs*REAL(bps)+1000000) / 4000000 + 0.5);
		n := MAX(1,MIN(255,n-1));
		uart.regs.rxtout := n;

		uart.regs.cr := uart.regs.cr + {PsUartMin.XUARTPS_CR_TORST}; (* restart receive timeout counter *)

		uart.regs.rxwm := 32; (* RX FIFO triggering threshold *)

		uart.regs.ier := RxInterrupts;

		PsUartMin.Enable(uart.regs,TRUE);

		res := 0;
		uart.open := TRUE;
	END Open;

	(**
		Close a UART controller

		uart: UART controller
	*)
	PROCEDURE Close*(uart: UartController);
	BEGIN
		IF uart.open THEN
			uart.open := FALSE;
			DisableInterrupts(uart.regs);
			PsUartMin.Enable(uart.regs,FALSE);
		END;
	END Close;

	PROCEDURE OccupiedBufSpace(bufWrPos, bufRdPos, bufSize: SIZE): SIZE;
	VAR n: SIZE;
	BEGIN
		n := bufWrPos - bufRdPos;
		IF n >= 0 THEN
			RETURN n;
		ELSE
			RETURN n+bufSize;
		END;
	END OccupiedBufSpace;

	(* Returns the amount of available free space in a cyclic buffer *)
	PROCEDURE AvailableBufSpace(bufWrPos, bufRdPos, bufSize: SIZE): SIZE;
	VAR n: SIZE;
	BEGIN
		n := bufWrPos - bufRdPos;
		IF n >= 0 THEN
			RETURN bufSize-1-n;
		ELSE
			RETURN -n-1;
		END;
	END AvailableBufSpace;

	(**
		Returns number of bytes available in the receive buffer of a UART controller

		uart: UART controller
		res: error code, 0 in case of success
	*)
	PROCEDURE Available*(uart: UartController): SIZE;
	BEGIN
		RETURN OccupiedBufSpace(uart.rxBufWrPos,uart.rxBufRdPos,LEN(uart.rxBuf));
	END Available;

	(**
		Send a single character to the UART

		ch: character to send
		propagate: TRUE for flushing the TX FIFO buffer
		res: error code, 0 in case of success
	*)
	PROCEDURE SendChar*(uart: UartController; ch: CHAR; propagate: BOOLEAN; onBusy: PsUartMin.BusyLoopCallback; VAR res: WORD);
	BEGIN
		PsUartMin.SendChar(uart.regs,ch,propagate,onBusy,res);
	END SendChar;

	(**
		Send data to the UART
	*)
	PROCEDURE Send*(uart: UartController; CONST buf: ARRAY OF CHAR; offs, len: LONGINT; propagate: BOOLEAN; onBusy: PsUartMin.BusyLoopCallback; VAR res: WORD);
	BEGIN
		WHILE uart.open & (len > 0) DO
			IF ~(PsUartMin.XUARTPS_SR_TNFUL IN uart.regs.sr) THEN
				uart.regs.fifo := ORD(buf[offs]);
				INC(offs); DEC(len);
			ELSIF (onBusy # NIL) & ~onBusy(res) THEN
				RETURN;
			END;
		END;

		IF propagate THEN (* flush the FIFO *)
			WHILE uart.open & ~(PsUartMin.XUARTPS_SR_TXEMPTY IN uart.regs.sr) DO
				IF (onBusy # NIL) & ~onBusy(res) THEN RETURN; END;
			END;
		END;

		IF uart.open THEN
			res := PsUartMin.Ok;
		ELSE
			res := PsUartMin.Closed;
		END;
	END Send;

	(**
		Receive a single character from UART

		res: error code, 0 in case of success

		Remarks: blocks until a character is available
	*)
	PROCEDURE ReceiveChar*(uart: UartController; onBusy: PsUartMin.BusyLoopCallback; VAR res: WORD): CHAR;
	VAR
		buf: ARRAY 1 OF CHAR;
		len: LONGINT;
	BEGIN
		Receive(uart,buf,0,1,1,len,onBusy,res);
		RETURN buf[0];
	END ReceiveChar;

	(**
		Receive data from the UART
	*)
	PROCEDURE Receive*(uart: UartController; VAR buf: ARRAY OF CHAR; offs, size, min: LONGINT; VAR len: LONGINT; onBusy: PsUartMin.BusyLoopCallback; VAR res: WORD);
	VAR
		bufRdPos, bufWrPos, n: SIZE;
	BEGIN
		IF ~uart.open THEN res := PsUartMin.Closed; RETURN; END;

		res := 0;
		len := 0;

		IF size = 0 THEN RETURN; END;

		min := MIN(size,min);

		WHILE uart.open & (size > 0) DO

			bufRdPos := uart.rxBufRdPos;
			bufWrPos := uart.rxBufWrPos;

			n := OccupiedBufSpace(bufWrPos,bufRdPos,LEN(uart.rxBuf));

			IF n # 0 THEN

				n := MIN(n,size);
				DEC(size,n); INC(len,n);
				IF min > 0 THEN DEC(min,n); END;

				(*!
					Make sure the receive buffer content
					corresponds to the state of uart.rxBufWrPos
				*)
				CODE
					DMB
				END;

				WHILE n > 0 DO
					buf[offs] := uart.rxBuf[bufRdPos];
					INC(bufRdPos);
					IF bufRdPos = LEN(uart.rxBuf) THEN
						bufRdPos := 0;
					END;
					INC(offs); DEC(n);
				END;

				uart.rxBufRdPos := bufRdPos;

			ELSIF min > 0 THEN
				IF (onBusy # NIL) & ~onBusy(res) THEN RETURN; END;
			ELSE
				RETURN;
			END;
		END;
	END Receive;

	PROCEDURE PrintRegisters(regs: PsUartMin.UartRegisters);
	BEGIN
		Trace.String("cr("); Trace.Hex(ADDRESSOF(regs.cr),-8); Trace.String("): "); Trace.Set(regs.cr); Trace.Ln;
		Trace.String("mr("); Trace.Hex(ADDRESSOF(regs.mr),-8); Trace.String("): "); Trace.Set(regs.mr); Trace.Ln;
		Trace.String("ier(");  Trace.Hex(ADDRESSOF(regs.ier),-8); Trace.String("): write only"); Trace.Ln;
		Trace.String("idr("); Trace.Hex(ADDRESSOF(regs.idr),-8); Trace.String("): write only"); Trace.Ln;
		Trace.String("imr("); Trace.Hex(ADDRESSOF(regs.imr),-8); Trace.String("): "); Trace.Set(regs.imr); Trace.Ln;
		Trace.String("isr("); Trace.Hex(ADDRESSOF(regs.isr),-8); Trace.String("): "); Trace.Set(regs.isr); Trace.Ln;
		Trace.String("baudgen("); Trace.Hex(ADDRESSOF(regs.baudgen),-8); Trace.String("): "); Trace.Int(regs.baudgen,0); Trace.Ln;
		Trace.String("rxtout("); Trace.Hex(ADDRESSOF(regs.rxtout),-8); Trace.String("): "); Trace.Int(regs.rxtout,0); Trace.Ln;
		Trace.String("rxwm("); Trace.Hex(ADDRESSOF(regs.rxwm),-8); Trace.String("): "); Trace.Int(regs.rxwm,0); Trace.Ln;
		Trace.String("modemcr("); Trace.Hex(ADDRESSOF(regs.modemcr),-8); Trace.String("): "); Trace.Set(regs.modemcr); Trace.Ln;
		Trace.String("modemsr("); Trace.Hex(ADDRESSOF(regs.modemsr),-8); Trace.String("): "); Trace.Set(regs.modemsr); Trace.Ln;
		Trace.String("sr("); Trace.Hex(ADDRESSOF(regs.sr),-8); Trace.String("): "); Trace.Set(regs.sr); Trace.Ln;
		Trace.String("fifo(");  Trace.Hex(ADDRESSOF(regs.fifo),-8); Trace.String("): --- "); Trace.Ln;
		Trace.String("bauddiv("); Trace.Hex(ADDRESSOF(regs.bauddiv),-8); Trace.String("): "); Trace.Int(regs.bauddiv,0); Trace.Ln;
		Trace.String("flowdel("); Trace.Hex(ADDRESSOF(regs.flowdel),-8); Trace.String("): "); Trace.Int(regs.flowdel,0); Trace.Ln;
		Trace.String("txwm("); Trace.Hex(ADDRESSOF(regs.txwm),-8); Trace.String("): "); Trace.Int(regs.txwm,0); Trace.Ln;
	END PrintRegisters;

	PROCEDURE Show*;
	BEGIN
		IF uarts[0] # NIL THEN
			Trace.StringLn("PS UART0:");
			PrintRegisters(uarts[0].regs);
			Trace.String("rxBufRdPos="); Trace.Int(uarts[0].rxBufRdPos,0); Trace.Ln;
			Trace.String("rxBufWrPos="); Trace.Int(uarts[0].rxBufWrPos,0); Trace.Ln;
			Trace.Ln;
		END;
		IF uarts[1] # NIL THEN
			Trace.StringLn("PS UART1:");
			PrintRegisters(uarts[1].regs);
			Trace.String("rxBufRdPos="); Trace.Int(uarts[1].rxBufRdPos,0); Trace.Ln;
			Trace.String("rxBufWrPos="); Trace.Int(uarts[1].rxBufWrPos,0); Trace.Ln;
			Trace.Ln;
		END;

	END Show;

END PsUart.