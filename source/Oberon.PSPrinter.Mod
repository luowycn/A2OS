(* ETH Oberon, Copyright 2001 ETH Zuerich Institut fuer Computersysteme, ETH Zentrum, CH-8092 Zuerich.
Refer to the "General ETH Oberon System Source License" contract available at: http://www.oberon.ethz.ch/ *)

MODULE PSPrinter IN Oberon; (** portable *)	(*UNIX version: JT 11.5.90, RC 2.7.93,  JS 29.4.9, Windows version: jm 20.12.95 *)

	(*
		wdm 2000-02-21 duplex printing: uses option "x"
		jm 20.12.95 EPS support added
		ps 4.8.96 added border to page (left, right: 2cm / top, bottom: 1.5 cm)
	*)

	IMPORT Files, Modules, Printer, Objects, Fonts, Texts, Strings, Oberon, Pictures;

	CONST
		N = 20;	(* max spline points *)
		maxFonts = 64;
		headerFileName = "PSHeader.Text";
		bold = 0; italics = 1; medium = 2;
		oneup = 0;  twoup = 1;  fourup = 2;  rotated = 3;

	TYPE
		Name* = ARRAY 32 OF CHAR;

		PSPrinter* = POINTER TO PSPrinterDesc;
		PSPrinterDesc* = RECORD (Printer.PrinterDesc)
			Escape*: PROCEDURE (P: Printer.Printer; s: ARRAY OF CHAR);
			printF*: Files.File;
			eps*: BOOLEAN; (** Is EPS output being written? *)
			pno*: INTEGER; (** Current page being printer on (starts with 1) *)

			l, t, r, b: LONGINT;
			sx, sy: INTEGER; (* current string pos *)
			mode, location: SHORTINT;
			duplex: BOOLEAN; (* Print duplex pages *)
			anonymous: BOOLEAN
		END;

		FontDesc = RECORD
			name: Name;
			used: ARRAY 8 OF SET;
		END;
		RealVector = ARRAY N OF REAL;
		Poly = RECORD a, b, c, d, t: REAL END ;
		PolyVector = ARRAY N OF Poly;

		FontDef = POINTER TO FontDefDesc;
		FontDefDesc = RECORD
			name: ARRAY 64 OF CHAR;
			family: ARRAY 32 OF CHAR;
			size: INTEGER;
			attr: CHAR;
			next: FontDef
		END;

	VAR
		(* to do: many of these variables should be local to the printer object *)
		fontTable: ARRAY maxFonts + 1 OF FontDesc;	(* +1: workaround (compiler bug) *)
		fontIndex, curFont: INTEGER;
		listFont: Name;
		headerT: Texts.Text;
		bodyF: Files.File;
		writer: Files.Rider;
		ppos: LONGINT;
		hexArray: ARRAY 17 OF CHAR;
		curR, curG, curB, setR, setG, setB: INTEGER;

		metric: Objects.Library;
		fontMapDict: FontDef;
		fontMapDictN: INTEGER;
		default: Objects.Name;

	(* -- Output procedures -- *)

	PROCEDURE Ch (ch: CHAR);
	BEGIN
		Files.Write(writer, ch)
	END Ch;

	PROCEDURE Str (s: ARRAY OF CHAR);
		VAR i: INTEGER;
	BEGIN
		i := 0;
		WHILE s[i] # 0X DO Ch(s[i] ); INC(i) END;
	END Str;

	PROCEDURE Int (i: LONGINT);
		VAR j: LONGINT;
	BEGIN
		IF i = 0 THEN Ch("0") ELSIF i < 0 THEN i := -i; Ch("-") END;
		j := 1;
		WHILE i DIV j # 0 DO j := j * 10 END;
		WHILE j >= 10 DO j := j DIV 10; Ch(CHR(30H + (i DIV j) MOD 10)) END;
	END Int;

	PROCEDURE Hex2(ch: CHAR);
	BEGIN
		Ch(hexArray[ORD(ch) DIV 16]);
		Ch(hexArray[ORD(ch) MOD 16]);
	END Hex2;

	PROCEDURE Real(x: REAL);
	VAR
		n, i, xi: INTEGER;
		d: ARRAY 4 OF CHAR;
	BEGIN
		xi := SHORT(ENTIER(x));
		IF x = xi THEN Int(xi); RETURN END;
		IF x < 0 THEN Ch("-"); x := -x; xi := -xi END;
		Int(xi); Ch("."); x := x - xi;
		n := SHORT(ENTIER(x*1000));
		i := 0;
		REPEAT
			d[i] := CHR(n MOD 10+30H); n := n DIV 10; INC(i)
		UNTIL i = 3;
		WHILE i > 0 DO DEC(i); Ch(d[i]) END
	END Real;

	PROCEDURE Ln;
	BEGIN
		Ch(0DX);  Ch(0AX);
	END Ln;

	(* -- Error handling -- *)

	PROCEDURE Error(s0, s1: ARRAY OF CHAR);
		VAR error, f: ARRAY 32 OF CHAR;
	BEGIN COPY(s0, error); COPY(s1, f); HALT(99)
	END Error;

	(* -- Bounding Box -- *)

	PROCEDURE Min(x, y: LONGINT): LONGINT;
	BEGIN IF x < y THEN RETURN x ELSE RETURN y END
	END Min;

	(* Increase the size of the bounding box. *)
	PROCEDURE Box*(P: PSPrinter; x, y, w, h: LONGINT);
	BEGIN
		IF x < P.l THEN P.l := x END;
		IF x + w - 1 > P.r THEN P.r := x + w - 1 END;
		IF y < P.b THEN P.b := y END;
		IF y + h - 1 > P.t THEN P.t := y + h - 1 END;
	END Box;

	(* -- Font Mapping -- *)

	PROCEDURE SetMappedFont(fname: ARRAY OF CHAR);
		VAR family: ARRAY 7 OF CHAR;
	BEGIN
		COPY(fname, family);
		Ch("/"); Str(fname);
		IF (family = "Syntax") OR (family = "Oberon") OR (family = "Default") THEN Str(" DefineSMapFont")
		ELSE Str(" DefineMapFont") END;
		Ln; Ln;
	END SetMappedFont;

	PROCEDURE SetBitmapFont(VAR R: Files.Rider; fd: FontDesc; pRes: INTEGER);
		TYPE
			RunRec = RECORD beg, end: INTEGER END;
			Metrics = RECORD dx, x, y, w, h: INTEGER END;

		VAR
			ch: CHAR;
			pixmapDX, n, b: LONGINT;
			k, m: INTEGER;
			height, minX, maxX, minY, maxY: INTEGER;
			nOfBoxes, nOfRuns: INTEGER;
			run: ARRAY 16 OF RunRec;
			metrics: ARRAY 256 OF Metrics;

		PROCEDURE Flip(ch: CHAR): CHAR;
			VAR i, s, d: INTEGER;
		BEGIN
			i := 0; s := ORD(ch); d := 0;
			WHILE i < 8 DO
				IF s MOD 2 = 1 THEN d := d * 2 + 1 ELSE d := d * 2 END;
				s := s DIV 2;
				INC(i)
			END;
			RETURN CHR(d);
		END Flip;

		PROCEDURE CharName(m: INTEGER);
		BEGIN
			CASE m OF
			| 9: Str("tab")
			| 32: Str("space")
			| 33: Str("exclam")
			| 34: Str("quotedbl")
			| 35: Str("numbersign")
			| 36: Str("dollar")
			| 37: Str("percent")
			| 38: Str("ampersand")
			| 39: Str("quotesingle")
			| 40: Str("parenleft")
			| 41: Str("parenright")
			| 42: Str("asterisk")
			| 43: Str("plus")
			| 44: Str("comma")
			| 45: Str("minus")
			| 46: Str("period")
			| 47: Str("slash")
			| 48: Str("zero")
			| 49: Str("one")
			| 50: Str("two")
			| 51: Str("three")
			| 52: Str("four")
			| 53: Str("five")
			| 54: Str("six")
			| 55: Str("seven")
			| 56: Str("eight")
			| 57: Str("nine")
			| 58: Str("colon")
			| 59: Str("semicolon")
			| 60: Str("less")
			| 61: Str("equal")
			| 62: Str("greater")
			| 63: Str("question")
			| 64: Str("at")
			| 65 .. 90: Ch(CHR(m))
			| 91: Str("bracketleft")
			| 92:  Str("backslash")
			| 93: Str("bracketright")
			| 94: Str("arrowup")
			| 95: Str("underscore")
			| 96: Str("grave")
			| 97 .. 122: Ch(CHR(m))
			| 123: Str("braceleft")
			| 124: Str("bar")
			| 125: Str("braceright")
			| 126: Str("tilde")
			| 128: Str("Adieresis")
			| 129: Str("Odieresis")
			| 130: Str("Udieresis")
			| 131: Str("adieresis")
			| 132: Str("odieresis")
			| 133: Str("udieresis")
			| 134: Str("acircumflex")
			| 135: Str("ecircumflex")
			| 136: Str("icircumflex")
			| 137: Str("oicircumflex")
			| 138: Str("uicircumflex")
			| 139: Str("agrave")
			| 140: Str("egrave")
			| 141: Str("igrave")
			| 142: Str("ograve")
			| 143: Str("ugrave")
			| 144: Str("eacute")
			| 145: Str("edieresis")
			| 146: Str("idieresis")
			| 147: Str("ccedilla")
			| 148: Str("aacute")
			| 149: Str("ntilde")
			| 150: Str("germandbls")
			| 155: Str("endash")
			| 159: Str("hyphen")
			ELSE
				Str("ascii");
				Ch(CHR(30H + (m DIV 100) MOD 10));
				Ch(CHR(30H + (m DIV 10) MOD 10));
				Ch(CHR(30H + m MOD 10))
			END
		END CharName;

	BEGIN
		Str("% Conversion of the Oberon font "); Str(fd.name); Ln;
		Files.Read(R, ch);
		IF ch = Fonts.FontId THEN
			Files.Read(R, ch); Str("% abstraction: "); Int(ORD(ch));
			Files.Read(R, ch); Str(", family: "); Ch(ch);
			Files.Read(R, ch); Str(", variant: "); Int(ORD(ch)); Ln;
			Files.ReadInt(R, height); Str("% height: "); Int(height); Ln; Ln;
			Files.ReadInt(R, minX); Files.ReadInt(R, maxX);
			Files.ReadInt(R, minY); Files.ReadInt(R, maxY);
			Files.ReadInt(R, nOfRuns);
			nOfBoxes := 0; k := 0;
			WHILE k # nOfRuns DO
				Files.ReadInt(R, run[k].beg); Files.ReadInt(R, run[k].end);
				INC(nOfBoxes, run[k].end - run[k].beg);
				INC(k)
			END;
			Str("9 dict begin"); Ln; Ln;
			Str("/FontType 3 def"); Ln;
			Str("/FontMatrix [ 72 "); Int(pRes); Str(" div "); Str(" factor1 div 0 0 ");
			Str("72 "); Int(pRes); Str(" div "); Str(" factor2 div 0 0");
			Str("] def"); Ln;
			Str("/FontBBox [");
			Int(minX); Ch(' ');
			Int(minY); Ch(' ');
			Int(maxX); Ch(' ');
			Int(maxY);
			Str("] def"); Ln; Ln;
			Str("/Encoding 256 array def"); Ln;
			Str("0 1 255 {Encoding exch /.notdef put} for"); Ln;
			Str("Encoding OberonEncoding /Encoding exch def"); Ln;
			Ln;
			Str("/CharData "); Int(nOfBoxes+1);
			Str(" dict def"); Ln;
			Str("CharData begin"); Ln;
			k := 0; m := 0;
			WHILE k < nOfRuns DO
				m := run[k].beg;
				WHILE m < run[k].end DO
					Files.ReadInt(R, metrics[m].dx);
					Files.ReadInt(R, metrics[m].x); Files.ReadInt(R, metrics[m].y);
					Files.ReadInt(R, metrics[m].w); Files.ReadInt(R, metrics[m].h);
					INC(m);
				END;
				INC(k)
			END;
			Str("/.notdef"); Str(" [");
			Int(metrics[32].w); Str(" 0 0 0 0 1 1 0 0"); Ln;
			Str("<>] bdef"); Ln;
			k := 0; m := 0;
			WHILE k < nOfRuns DO
				m := run[k].beg;
				WHILE m < run[k].end DO
					IF m MOD 32 IN fd.used[m DIV 32] THEN
						Str("/"); CharName(m); Str(" [");
						Int(metrics[m].dx); Ch(' ');
						Int(metrics[m].x); Ch(' '); Int(metrics[m].y); Ch(' ');
						Int(metrics[m].x + metrics[m].w); Ch(' ');
						Int(metrics[m].y + metrics[m].h); Ch(' ');
						IF metrics[m].w > 0 THEN Int(metrics[m].w); ELSE Int(1) END; Ch(' ');
						IF metrics[m].h > 0 THEN Int(metrics[m].h); ELSE Int(1) END; Ch(' ');
						Int(-metrics[m].x); Ch(' '); Int(-metrics[m].y); Ln;
						Str("<");
						pixmapDX := (metrics[m].w + 7) DIV 8;
						n := pixmapDX * metrics[m].h;
						b := 0;
						WHILE b < n DO
							Files.Read(R, ch); Hex2(Flip(ch));
							INC(b);
							IF b MOD 32 = 0 THEN Ln; Ch(' ') END
						END;
						Str(">] bdef"); Ln;
					ELSE
						n := (metrics[m].w + 7) DIV 8 * metrics[m].h;
						b := 0; WHILE b < n DO Files.Read(R, ch); INC(b) END;
					END;
					INC(m);
				END;
				INC(k)
			END;
			Str("  end"); Ln; Ln;
			Str("/BuildGlyph {GlobalBuildGlyph} bdef"); Ln;
			Str("/BuildChar {GlobalBuildChar} bdef"); Ln; Ln;
			Str("/imageMaskMatrix [1 0 0 1 0 0] bdef"); Ln; Ln;
			Str("currentdict"); Ln; Ln;
			Str("end"); Ln; Ln;
			Ch("/"); Str(fd.name);
			Str(" exch definefont pop"); Ln; Ln;
		END;
	END SetBitmapFont;

	PROCEDURE DefineFont(fd: FontDesc; echo: BOOLEAN);
		VAR
			family, name: ARRAY 32 OF CHAR;
			i, size, dpi: INTEGER;
			f: Files.File; R: Files.Rider;
			fontDef: FontDef;
			attr: CHAR;
	BEGIN
		dpi := SHORT(914400 DIV Printer.current.Unit);
		COPY(fd.name, name); i := 0; size := 0;
		WHILE (name[i] # 0X) & (name[i] # ".") & ((name[i] < "0") OR (name[i] > "9")) DO
			family[i] := name[i]; INC(i)
		END;
		family[i] := 0X;
		size := 0;
		WHILE (name[i] >= "0") & (name[i] <= "9") DO size := size * 10 + ORD(name[i]) - 30H; INC(i) END;
		attr := 0X;
		WHILE (name[i] # 0X) & (name[i] # ".") DO attr := CAP(name[i]); INC(i) END;
		fontDef := fontMapDict;
		WHILE (fontDef # NIL) & ~((fontDef.size = size) & (fontDef.attr = attr) & (fontDef.family = family)) DO
			fontDef := fontDef.next
		END;
		IF fontDef = NIL THEN
			NEW(fontDef); fontDef.next := fontMapDict; fontMapDict := fontDef; INC(fontMapDictN);
			COPY(name, fontDef.name); COPY(family, fontDef.family);
			fontDef.size := size; fontDef.attr := attr
		END;
		IF ~echo THEN RETURN END;
		IF (name[i] # ".") OR (name[i+1] # "S") OR (name[i+2] # "c") OR (name[i+3] # "n") THEN
			SetMappedFont (fd.name);
		ELSE
			name[i+1] := "P"; name[i+2] := "r";  name[i+3] := CHR((dpi DIV 100)+ORD("0"));
			f := Files.Old(name);
			IF f = NIL THEN
				SetMappedFont (fd.name);
			ELSE
				Files.Set(R, f, 0); SetBitmapFont(R, fd, dpi)
			END;
		END;
	END DefineFont;

	(* -- Metric Font loading -- *)

	PROCEDURE ParseName (VAR name, family: ARRAY OF CHAR; VAR size: LONGINT; VAR style: SET; VAR class: ARRAY OF CHAR);
	VAR i, j: INTEGER;
	BEGIN
		size := 0; style := {}; i := 0;
		WHILE (name[i] > "9") OR (name[i] = ' ') DO family[i] := name[i]; INC(i) END;
		family[i] := 0X;
		WHILE ("0" <= name[i]) & (name[i] <= "9") DO size := 10*size + (ORD(name[i]) - 30H); INC(i) END;
		WHILE (name[i] # 0X) & (name[i] # ".") DO
			CASE CAP(name[i]) OF
				| "I": INCL(style, italics); name[i] := "i"
				| "B": INCL(style, bold); name[i] := "b"
				| "M": INCL(style, medium); name[i] := "m"
			ELSE
			END;
			INC(i)
		END;
		j := 0;
		INC(i); WHILE (name[i] # 0X) & (name[i] # ".") DO class[j] := name[i]; INC(i); INC(j) END;
		class[j] := 0X;
	END ParseName;

	(* -- Exported Procedures -- *)

	PROCEDURE GetDim(P: Printer.Printer;  label: ARRAY OF CHAR;  def: INTEGER;  VAR val: INTEGER);
	VAR v: REAL; S: Texts.Scanner;
	BEGIN
		Oberon.OpenScanner(S, label);
		IF S.class IN {Texts.Int, Texts.Real} THEN
			IF S.class = Texts.Int THEN v := S.i
			ELSE v := S.x
			END;
			Texts.Scan(S);
			IF S.class IN {Texts.Name, Texts.String} THEN
				IF S.s = "cm" THEN v := v*360000.0
				ELSIF S.s = "mm" THEN v := v*36000.0
				ELSIF S.s = "in" THEN v := v*36000.0*25.4
				ELSE v := v*36000.0	(* default mm *)
				END
			ELSE v := v*36000.0	(* default mm *)
			END;
			val := SHORT(ENTIER(v/P.Unit + 0.5))
		ELSE
			val := SHORT(ENTIER(def*36000.0/P.Unit + 0.5))
		END
	END GetDim;

	PROCEDURE Swap(VAR x, y: INTEGER);
	VAR t: INTEGER;
	BEGIN
		t := x;  x := y;  y := t
	END Swap;

	PROCEDURE InitMetrics*(P: Printer.Printer);
	VAR S: Texts.Scanner;
	BEGIN
		Oberon.OpenScanner(S, "PSPrinter.Resolution");
		IF S.class # Texts.Int THEN S.i := 300 END;	(* default *)

		P.Unit := 914400 DIV S.i; P.Depth := 24;

		GetDim(P, "PSPrinter.Width", 210, P.Width);
		GetDim(P, "PSPrinter.Height", 297, P.Height);
		GetDim(P, "PSPrinter.LeftMargin", 20, P.FrameX);
		GetDim(P, "PSPrinter.RightMargin", 20, P.FrameW);
		P.FrameW := P.Width-P.FrameX-P.FrameW;
		GetDim(P, "PSPrinter.BottomMargin", 15, P.FrameY);
		GetDim(P, "PSPrinter.TopMargin", 15, P.FrameH);
		P.FrameH := P.Height-P.FrameY-P.FrameH;
		IF P(PSPrinter).mode = rotated THEN
			Swap(P.Width, P.Height);  Swap(P.FrameX, P.FrameY);  Swap(P.FrameW, P.FrameH)
		END
	END InitMetrics;

	PROCEDURE GetSuffix(VAR str(** in *), suf(** out *): ARRAY OF CHAR);
		VAR i, j, dot: LONGINT;
	BEGIN
		dot := -1; i := 0;
		WHILE str[i] # 0X DO
			IF str[i] = "." THEN dot := i END;
			INC(i)
		END;
		j := 0;
		IF dot > 0 THEN
			i := dot+1;
			WHILE str[i] # 0X DO
				suf[j] := str[i]; INC(j); INC(i)
			END
		END;
		suf[j] := 0X
	END GetSuffix;

	PROCEDURE SetColor;
	BEGIN
		IF (setR # curR) OR (setG # curG) OR (setB # curB) THEN
			setR := curR;  setG := curG;  setB := curB;
			Real(setR/255); Ch(' ');
			Real(setG/255); Ch(' ');
			Real(setB/255); Ch(' ');
			Str("u ");
			Ln
		END
	END SetColor;

	PROCEDURE ResetColor;
	BEGIN
		curR := 0; curG := 0; curB := 0;
		setR := 0;  setG := 0;  setB := 0	(* default color is black, set by /OberonInit and /p *)
	END ResetColor;

	PROCEDURE Open*(P: Printer.Printer; printer, options: ARRAY OF CHAR);
	VAR suffix: ARRAY 32 OF CHAR;  i: LONGINT;
	BEGIN
		WITH P: PSPrinter DO
			ResetColor;
			P.res := 1;	(* no such printer *)
			P.printF := Files.New(printer);
			IF P.printF = NIL THEN
				P.printF := Files.New(""); P.anonymous := TRUE
			ELSE
				P.anonymous := FALSE
			END;
			GetSuffix(printer, suffix);
			P.eps := (suffix = "EPS") OR (suffix = "eps");
			i := 0;  P.mode := oneup;  P.location := 0;
			WHILE (options[i] # 0X) & (options[i] # Oberon.OptionChar) DO
				IF options[i] = "l" THEN P.mode := twoup
				ELSIF options[i] = "d" THEN P.mode := fourup
				ELSIF options[i] = "e" THEN P.eps := TRUE
				ELSIF options[i] = "r" THEN P.mode := rotated
				ELSIF options[i] = "x" THEN P.duplex := TRUE
				END;
				INC(i)
			END;
			InitMetrics(P);
			fontMapDict := NIL; fontMapDictN := 0;
			P.l := MAX(LONGINT); P.r := MIN(LONGINT); P.t := MIN(LONGINT); P.b := MAX(LONGINT);

			NEW(headerT); Texts.Open(headerT, headerFileName);
			IF headerT.len > 0 THEN
				bodyF := Files.New(""); Files.Set(writer, bodyF, 0);
				fontIndex := -1; curFont := -1; listFont := ""; ppos := 0; P.pno := 1;
				P.res := 0
			ELSE
				Error("file not found", headerFileName)
			END
		END
	END Open;

	PROCEDURE UseListFont*(P: Printer.Printer; name: ARRAY OF CHAR);
	BEGIN
		COPY(name, listFont); curFont := -1
	END UseListFont;

	(** Don't forget to update the bounding box of eps files by calling procedure Box. *)
	PROCEDURE Escape*(P: Printer.Printer; s: ARRAY OF CHAR);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			Str(s)
		END
	END Escape;

	PROCEDURE ReplConst*(P: Printer.Printer; x, y, w, h: INTEGER);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			IF (w > 0) & (h > 0) THEN
				SetColor;
				Box(P, x, y, w, h);
				Int(x+1); Ch(' ');
				Int(y);  Ch(' ');
				Int(w-1); Ch(' ');
				Int(h-1); Str(" l"); Ln;
			END
		END
	END ReplConst;

	PROCEDURE StringSize(VAR s: ARRAY OF CHAR; fnt: Fonts.Font; VAR w, h, dsr: INTEGER);
	VAR p: INTEGER; obj: Objects.Object;
	BEGIN
		w := 0; h := 0; dsr := 0;
		p := 0;
		IF (metric = NIL) OR (fnt.name # metric.name) THEN metric := Printer.GetMetric(fnt) END;
		IF (metric # NIL) & (metric(Fonts.Font).type = Fonts.metric) THEN
			WHILE s[p] # 0X DO
				metric.GetObj(metric, ORD(s[p]), obj);
				INC(w, obj(Fonts.Char).dx);
				INC(p)
			END;
			h := metric(Fonts.Font).height;
			dsr := ABS(metric(Fonts.Font).minY);
		END
	END StringSize;

	PROCEDURE ContString*(P: Printer.Printer; s: ARRAY OF CHAR; fnt: Fonts.Font);
		VAR fNo, i, n, w, h, dsr: INTEGER; ch: CHAR; family: ARRAY 7 OF CHAR;

		PROCEDURE Use(ch: CHAR);
		BEGIN
			INCL(fontTable[curFont].used[ORD(ch) DIV 32], ORD(ch) MOD 32);
		END Use;

	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			StringSize(s, fnt, w, h, dsr);
			Box(P, P.sx - dsr, P.sy, w, h);
			INC(P.sx, w);
			IF (curFont < 0) OR (fontTable[curFont].name # fnt.name) THEN
				COPY(fnt.name, fontTable[fontIndex+1].name);
				i := 0; WHILE i < 8 DO fontTable[fontIndex+1].used[i] := {}; INC(i) END;
				fNo := 0;
				WHILE fontTable[fNo].name # fnt.name DO INC(fNo) END;
				IF fNo > fontIndex THEN (* DefineFont(fname); *) fontIndex := fNo END;
				curFont := fNo; Ch("(");
				IF fontTable[curFont].name = listFont THEN
					Str("Courier8.Scn.Fnt")
				ELSE
					Str(fontTable[curFont].name)
				END;
				Str(") f ")
			END;
			Ch("(");
			i := 0; ch := s[0];
			WHILE ch # 0X DO
				CASE ch OF
				| "(", ")", "\": Ch("\"); Ch(ch); Use(ch);
				| 9X: Str("  "); Use(' ')	(* or Str("\tab") *)
				| 80X..95X, 0ABX:
					Str("\2"); n := ORD(ch)-128;
					Ch(CHR(n DIV 8 + 48)); Ch(CHR(n MOD 8 + 48)); Use(ch)
				| 9FX: COPY(fontTable[curFont].name, family);
					IF family = "Courier" THEN Ch(' ') ELSE Str("  ") END; Use(' ');
				ELSE
					Ch(ch); Use(ch);
				END ;
				INC(i); ch := s[i];
			END;
			Str(") s"); Ln
		END
	END ContString;

	PROCEDURE String*(P: Printer.Printer; x, y: INTEGER; s: ARRAY OF CHAR; fnt: Fonts.Font);
	VAR w, h, dsr: INTEGER;
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			StringSize(s, fnt, w, h, dsr);
			Box(P, x - dsr, y, w, h);
			P.sx := x + w; P.sy := y;

			Int(x); Ch(' ');
			Int(y); Str(" m "); ContString(P, s, fnt)
		END
	END String;

	PROCEDURE ReplPattern*(P: Printer.Printer; x, y, w, h, col: INTEGER);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			Box(P, x, y, w, h);
			Int(x+1); Ch(' ');
			Int(y); Ch(' ');
			Int(w-1); Ch(' ');
			Int(h-1); Ch(' ');
			Int(col); Str(" b"); Ln
		END
	END ReplPattern;

	(* mode is not used *)
	PROCEDURE Picture*(P: Printer.Printer; pict: Pictures.Picture; sx, sy, sw, sh, dx, dy, dw, dh, mode: INTEGER);
	VAR
		x, y: INTEGER;
		n, h0, h1, k, i: INTEGER;
		h: ARRAY 128 OF INTEGER;

		PROCEDURE WColTab(n: INTEGER);
		VAR i, r, g, b: INTEGER;
		BEGIN
			i := 0; WHILE i < n DO Pictures.GetColor(pict, i, r, g, b); Hex2(CHR(r)); INC(i) END; Ln;
			i := 0; WHILE i < n DO Pictures.GetColor(pict, i, r, g, b); Hex2(CHR(g)); INC(i) END; Ln;
			i := 0; WHILE i < n DO Pictures.GetColor(pict, i, r, g, b); Hex2(CHR(b)); INC(i) END; Ln;
		END WColTab;

		PROCEDURE H(n: INTEGER);
		VAR d0, d1: INTEGER;
		BEGIN
			d0 := n MOD 16; IF d0 > 9 THEN INC(d0, 7) END;
			d1 := n DIV 16; IF d1 > 9 THEN INC(d1, 7) END;
			Ch(CHR(d1+30H)); Ch(CHR(d0+30H))
		END H;

		PROCEDURE Out;
		BEGIN
			IF n > 0 THEN
				IF n = 1 THEN H(0); H(h[0])
				ELSIF (n = 2) & (h[0] = h[1]) THEN H(81H); H(h[0])
				ELSE H(n-1); i := 0; WHILE i < n DO H(h[i]); INC(i) END
				END;
				n := 0
			END;
			WHILE k > 128 DO H(127+128); H(h0); DEC(k, 128) END;
			H(127+k); H(h0)
		END Out;

	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			Box(P, dx, dy, dw, dh);
			Str("gsave ");  Int(dx);  Ch(' ');  Int(dy);  Str(" translate ");
			Real(dw/sw); Ch(' '); Real(dh/sh); Str(" scale ");

			Int(sw);  Ch(' ');  Int(sh);  Str(" rlepic ");
			WColTab(256);

			y := sy + sh - 1;
			WHILE y >= sy DO
				n := 0; x := sx;
				h0 := Pictures.Get(pict, x, y); INC(x); k := 1;
				WHILE x < sx + sw DO
					h1 := Pictures.Get(pict, x, y); h[n] := h1;
					IF h1 = h0 THEN INC(k)
					ELSE
						IF k < 3 THEN
							IF n + k >= 128 THEN H(127);
								i := 0; WHILE i < n DO H(h[i]); INC(i) END;
								i := 0; WHILE n + i < 128 DO H(h0); INC(i); DEC(k) END;
								n := 0
							END;
							WHILE k > 0 DO DEC(k); h[n] := h0; INC(n) END
						ELSE Out
						END;
						h0 := h1; k := 1
					END;
					INC(x)
				END;
				Out;
				DEC(y); Ln
			END;
			Ln;
			Str("grestore "); Ln
		END
	END Picture;

	PROCEDURE Circle*(P: Printer.Printer; x0, y0, r: INTEGER);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			Box(P, x0 - r, y0 - r, r * 2, r * 2);
			Int(x0); Ch(' ');
			Int(y0); Ch(' ');
			Int(r); Ch(' ');
			Int(r); Str(" c");
			Ln
		END
	END Circle;

	PROCEDURE Ellipse*(P: Printer.Printer; x0, y0, a, b: INTEGER);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			Box(P, x0 - a, y0 - b, a * 2 , b * 2);
			Int(x0); Ch(' ');
			Int(y0); Ch(' ');
			Int(a); Ch(' ');
			Int(b); Str(" c");
			Ln
		END
	END Ellipse;

	PROCEDURE Line*(P: Printer.Printer; x0, y0, x1, y1: INTEGER);
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			Box(P, Min(x0, x1), Min(y0, y1), ABS(x1 - x0), ABS(y1 - y0));
			Int(x0); Ch(' ');
			Int(y0); Ch(' ');
			Int(x1-x0); Ch(' ');
			Int(y1-y0); Str(" x");
			Ln
		END
	END Line;

	PROCEDURE UseColor*(P: Printer.Printer; red, green, blue: INTEGER);
	BEGIN
		curR := red;  curG := green;  curB := blue
	END UseColor;

	(* -- Spline computation -- *)

	PROCEDURE SolveTriDiag(VAR a, b, c, y: RealVector; n: INTEGER);
		VAR i: INTEGER; t, tt: REAL;
	BEGIN (*a, b, c of tri-diag matrix T; solve Ty' = y for y', assign y' to y*)
		i := 1;
		WHILE i < n DO t := y[i-1]; y[i] := y[i] - c[i-1]*t; INC(i) END ;
		i := n-1; y[i] := y[i]/a[i];
		WHILE i > 0 DO DEC(i); t := a[i]; tt := b[i]*y[i+1]; y[i] := (y[i] - tt)/t END
	END SolveTriDiag;

	PROCEDURE OpenSpline(VAR x, y, d: RealVector; n: INTEGER);
		VAR i: INTEGER; d1, d2: REAL;
			a, b, c: RealVector;
	BEGIN (*from x, y compute d = y'*)
		b[0] := 1.0/(x[1] - x[0]); a[0] := 2.0*b[0]; c[0] := b[0];
		d1 := (y[1] - y[0])*3.0*b[0]*b[0]; d[0] := d1; i := 1;
		WHILE i < n-1 DO
			b[i] := 1.0 / (x[i+1] - x[i]);
			a[i] := 2.0 * (c[i-1] + b[i]);
			c[i] := b[i];
			d2 := (y[i+1] - y[i])*3.0*b[i]*b[i];
			d[i] := d1 + d2; d1 := d2; INC(i)
		END ;
		a[i] := 2.0*b[i-1]; d[i] := d1; i := 0;
		WHILE i < n-1 DO c[i] := c[i]/a[i]; a[i+1] := a[i+1] - c[i]*b[i]; INC(i) END ;
		SolveTriDiag(a, b, c, d, n)
	END OpenSpline;

	PROCEDURE ClosedSpline(VAR x, y, d: RealVector; n: INTEGER);
		VAR i: INTEGER; d1, d2, hn, dn: REAL;
			a, b, c, w: RealVector;
	BEGIN (*from x, y compute d = y'*)
		hn := 1.0/(x[n-1] - x[n-2]);
		dn := (y[n-1] - y[n-2])*3.0*hn*hn;
		b[0] := 1.0/(x[1] - x[0]);
		a[0] := 2.0*b[0] + hn;
		c[0] := b[0];
		d1 := (y[1] - y[0])*3.0*b[0]*b[0]; d[0] := dn + d1;
		w[0] := 1.0; i := 1;
		WHILE i < n-2 DO
			b[i] := 1.0/(x[i+1] - x[i]);
			a[i] := 2.0*(c[i-1] + b[i]);
			c[i] := b[i];
			d2 := (y[i+1] - y[i])*3.0*b[i]*b[i]; d[i] := d1 + d2; d1 := d2;
			w[i] := 0; INC(i)
		END ;
		a[i] := 2.0*b[i-1] + hn; d[i] := d1 + dn;
		w[i] := 1.0; i := 0;
		WHILE i < n-2 DO c[i] := c[i]/a[i]; a[i+1] := a[i+1] - c[i]*b[i]; INC(i) END ;
		SolveTriDiag(a, b, c, d, n-1); SolveTriDiag(a, b, c, w, n-1);
		d1 := (d[0] + d[i])/(w[0] + w[i] + x[i+1] - x[i]); i := 0;
		WHILE i < n-1 DO d[i] := d[i] - d1*w[i]; INC(i) END ;
		d[i] := d[0]
	END ClosedSpline;

	PROCEDURE PrintPoly(P: PSPrinter; VAR p, q: Poly; lim: REAL);
		VAR x0, y0, x1, y1, x2, y2, x3, y3: REAL;
			xx0, yy0, xx1, yy1, xx2, yy2, xx3, yy3: LONGINT;

	BEGIN
		x0 := p.d;
		y0 := q.d;
		x1 := x0 + p.c*lim/3.0;
		y1 := y0 + q.c*lim/3.0;
		x2 := x1 + (p.c + p.b*lim)*lim/3.0;
		y2 := y1 + (q.c + q.b*lim)*lim/3.0;
		x3 := x0 + (p.c + (p.b + p.a*lim)*lim)*lim;
		y3 := y0 + (q.c + (q.b + q.a*lim)*lim)*lim;

		xx0 := ENTIER(x0); yy0 := ENTIER(y0); xx1 := ENTIER(x1); yy1 := ENTIER(y1);
		xx2 := ENTIER(x2); yy2 := ENTIER(y2); xx3 := ENTIER(x3); yy3 := ENTIER(y3);

		Int(xx1); Ch(' ');
		Int(yy1); Ch(' ');
		Int(xx2); Ch(' ');
		Box(P, Min(xx1, xx2), Min(yy1, yy2), ABS(xx2-xx1), ABS(yy2-yy1));

		Int(yy2); Ch(' ');
		Int(xx3); Ch(' ');
		Box(P, Min(xx2, xx3), Min(yy2, yy3), ABS(xx3-xx2), ABS(yy3-yy2));

		Int(yy3); Ch(' ');
		Int(xx0); Ch(' ');
		Int(yy0); Str(" z");
		Box(P, Min(xx3, xx0), Min(yy3, yy0), ABS(xx0-xx3), ABS(yy0-yy3));

		Ln;
	END PrintPoly;

	PROCEDURE Spline*(P: Printer.Printer; x0, y0, n, open: INTEGER; VAR X, Y: ARRAY OF INTEGER);
		VAR i: INTEGER; dx, dy, ds: REAL;
			x, xd, y, yd, s: RealVector;
			p, q: PolyVector;
	BEGIN
		WITH P: PSPrinter DO
			(* Don't make more that one page when making eps *)
			IF P.eps & (P.pno > 1) THEN RETURN END;
			SetColor;
			(*from u, v compute x, y, s*)
			x[0] := X[0] + x0; y[0] := Y[0] + y0; s[0] := 0; i := 1;
			WHILE i < n DO
				x[i] := X[i] + x0; dx := x[i] - x[i-1];
				y[i] := Y[i] + y0; dy := y[i] - y[i-1];
				s[i] := ABS(dx) + ABS(dy) + s[i-1]; INC(i)
			END ;
			IF open = 1 THEN OpenSpline(s, x, xd, n); OpenSpline(s, y, yd, n)
			ELSE ClosedSpline(s, x, xd, n); ClosedSpline(s, y, yd, n)
			END ;
			(*compute coefficients from x, y, xd, yd, s*)  i := 0;
			WHILE i < n-1 DO
				ds := 1.0/(s[i+1] - s[i]);
				dx := (x[i+1] - x[i])*ds;
				p[i].a := ds*ds*(xd[i] + xd[i+1] - 2.0*dx);
				p[i].b := ds*(3.0*dx - 2.0*xd[i] -xd[i+1]);
				p[i].c := xd[i];
				p[i].d := x[i];
				p[i].t := s[i];
				dy := ds*(y[i+1] - y[i]);
				q[i].a := ds*ds*(yd[i] + yd[i+1] - 2.0*dy);
				q[i].b := ds*(3.0*dy - 2.0*yd[i] - yd[i+1]);
				q[i].c := yd[i];
				q[i].d := y[i];
				q[i].t := s[i]; INC(i)
			END ;
			p[i].t := s[i]; q[i].t := s[i];
			(*print polynomials*)
			i := 0;
			WHILE i < n-1 DO PrintPoly(P, p[i], q[i], p[i+1].t - p[i].t); INC(i) END
		END
	END Spline;

	PROCEDURE Page*(P: Printer.Printer; nofcopies: INTEGER);
	VAR x, y: LONGINT;
	BEGIN
		WITH P: PSPrinter DO
			ResetColor;
			CASE P.mode OF
				oneup, rotated:
					IF ~P.eps THEN
						Int(nofcopies); Str(" p"); Ln
					END;
					curFont := -1; INC(P.pno); ppos := Files.Pos(writer);
					Str("%%Page: 0 "); Int(P.pno); Ln;
				|twoup:
					x := 2336 * 3048 DIV P.Unit;
					CASE P.location OF
						| 0: Int(x);  Str(" 0 translate"); Ln
						| 1: Int(-x);  Str(" 0 translate"); Ln;
							Int(nofcopies); Str(" p"); Ln;
							curFont := -1; INC(P.pno); ppos := Files.Pos(writer);
							Str("%%Page: 0 "); Int(P.pno); Ln
					END; (* CASE *)
					P.location := 1-P.location
				|fourup:
					x := 2336 * 3048 DIV P.Unit;  y := 3520 * 3048 DIV P.Unit;
					CASE P.location OF
						| 0: Int(x);  Str(" 0 translate"); Ln
						| 1: Int(-x);  Ch(' ');  Int(-y);  Str(" translate"); Ln
						| 2: Int(x);  Str(" 0 translate"); Ln
						| 3: Int(-x);  Ch(' ');  Int(y);  Str(" translate"); Ln;
							Int(nofcopies); Str(" p"); Ln;
							curFont := -1; INC(P.pno); ppos := Files.Pos(writer);
							Str("%%Page: 0 "); Int(P.pno); Ln
					END; (* CASE *)
					P.location := (P.location+1) MOD 4
			END (* CASE *)
		END
	END Page;

	PROCEDURE Close*(P: Printer.Printer);
		CONST bufSize = 4*1024;
		VAR
			dpi: LONGINT;
			i: INTEGER;
			reader: Files.Rider; buffer: ARRAY bufSize OF CHAR;
			S: Texts.Scanner;
			R: Texts.Reader; ch: CHAR;
			fontDef: FontDef;
			alias: ARRAY 64 OF CHAR;
	BEGIN
		WITH P: PSPrinter DO
			dpi := 914400 DIV Printer.current.Unit;
			IF (P.mode # oneup) & (P.location # 0) THEN
				Int(1); Str(" p"); Ln;
				curFont := -1; INC(P.pno); ppos := Files.Pos(writer)
			END;
			Files.Set(writer, bodyF, ppos);	(*overwrite last %%Page line*)
			Str("%%Trailer         "); Ln;
			Str("restore"); Ln;	(* page save *)
			Str("restore"); Ln;	(* header file save *)

			Files.Set(writer, P.printF, 0);

			IF P.eps & (P.l <= P.r) & (P.b <= P.t) THEN
				Str("%!PS-Adobe-1.0"); Ln;
				Str("%%BoundingBox: ");
				Int(0); Ch(' '); Int(0); Ch(' ');
				Int((P.r - P.l + 1)* 72 DIV (914400 DIV P.Unit)); Ch(' ');
				Int((P.t - P.b + 1) * 72 DIV (914400 DIV P.Unit)); Ch(' ');
				Ln;
				Str("%%Creator: ETH Oberon"); Ln;
				Str("%%EndComments"); Ln;
			END;

			Texts.OpenReader(R, headerT, 0);
			Texts.Read(R, ch);
			WHILE ~R.eot DO
				Ch(ch);
				IF ch = 0DX THEN Ch(0AX) END;
				Texts.Read(R, ch)
			END;
			IF P.duplex THEN
				Str("statusdict /setduplexmode known {statusdict begin true setduplexmode end} if");
				Ln; Ln
			END;
			Str("/factor1 ");  Real(P.Unit/12700.0);  Str(" def");  Ln;
			Str("/factor2 ");  Real(P.Unit/12700.0);  Str(" def");  Ln;  Ln;
			i := 0;
			WHILE i <= fontIndex DO DefineFont(fontTable[i], FALSE); INC(i) END;
			IF fontMapDictN > 0 THEN
				Str("/FontMapDict "); Int(fontMapDictN); Str(" dict def"); Ln;
				Str("FontMapDict begin"); Ln;
				fontDef := fontMapDict;
				WHILE fontDef # NIL DO
					Ch("/"); Str(fontDef.name); Str(" [/");
					IF (fontDef.family = "Syntax") OR (fontDef.family = "Oberon") OR (fontDef.family = "Default") THEN
						Str("Helvetica");
						CASE fontDef.attr OF
							|"I"		: Str("-Oblique")
							|"M", "B"	: Str("-Bold")
						ELSE
						END;
						Ch(' ');
						Int(fontDef.size*(4*dpi) DIV 300)
						(*Int((fontDef.size*11+2)*dpi DIV 100)*)
					ELSIF (fontDef.family = "Helvetica") OR (fontDef.family = "Courier") THEN
						Str(fontDef.family);
						CASE fontDef.attr OF
							|"I"		: Str("-Oblique")
							|"M", "B"	: Str("-Bold")
						ELSE
						END;
						Ch(' ');
						Int(fontDef.size*(4*dpi) DIV 300)
					ELSIF fontDef.family = "Times" THEN
						Str("Times");
						CASE fontDef.attr OF
							|"I"		: Str("-Italic")
							|"M", "B"	: Str("-Bold")
						ELSE
							Str("-Roman")
						END;
						Ch(' ');
						Int(fontDef.size*(4*dpi) DIV 300)
					ELSE
						buffer := "PSPrinter."; Strings.Append(buffer, fontDef.family);
						Oberon.OpenScanner (S, buffer);
						IF S.class IN {Texts.Name, Texts.String} THEN
							COPY(S.s, alias); Str(alias)
						ELSE
							Str(fontDef.family)
						END;
						CASE fontDef.attr OF
							|"I"		: Str("-Italic")
							|"M", "B"	: Str("-Bold")
						ELSE
						END;
						Ch(' ');
						Int(fontDef.size*(4*dpi) DIV 300)
					END;
					Str("] def"); Ln;
					fontDef := fontDef.next
				END;
				Str("end"); Ln;
				fontMapDict := NIL; fontMapDictN := 0
			END;
			Ln;
			i := 0;
			WHILE i <= fontIndex DO DefineFont(fontTable[i], TRUE); INC(i) END;
			Ln;
			Str("OberonInit"); Ln; Ln;
			CASE P.mode OF
				oneup:
					(* skip *)
				|twoup:
					Str("90 rotate"); Ln;
					Str("0.7071 0.7071 scale"); Ln;
					Str("0 ");  Int(-3520 * 3048 DIV P.Unit); Str(" translate"); Ln
				|fourup:
					Str("0.5 0.5 scale"); Ln;
					Str("0 ");  Int(3520 * 3048 DIV P.Unit); Str(" translate"); Ln
				|rotated:
					Str("90 rotate"); Ln;
					Str("0 ");  Int(-2489 * 3048 DIV P.Unit); Str(" translate"); Ln
			END;
			Str("save"); Ln; Ln;
			Str("%%EndProlog"); Ln;
			Str("%%Page: 0 1"); Ln;

			Ln;

			IF P.eps THEN
				Int(-P.l);  Ch(' ');  Int(-P.b);  Str(" translate");  Ln;
			END;

			Files.Set(reader, bodyF, 0);
			REPEAT
				Files.ReadBytes(reader, buffer, bufSize);
				Files.WriteBytes(writer, buffer, bufSize - reader.res)
			UNTIL reader.eof;
			IF ~P.anonymous THEN Printer.Spool(P.printF) END;
			P.res := Printer.res;

			Files.Set(writer, NIL, 0);
			headerT := NIL; bodyF := NIL
		END
	END Close;

	PROCEDURE GetMetric* (P: Printer.Printer; fnt: Fonts.Font): Fonts.Font;
	VAR name: ARRAY 32 OF CHAR; i: INTEGER; metric: Fonts.Font;
	BEGIN
		COPY(fnt.name, name);
		i := 0; WHILE (name[i] # ".") & (name[i] # 0X) DO INC(i) END;
		(* look for Mdx *)
		name[i] := "."; name[i+1] := "M"; name[i+2] := "d";
		name[i+3] := CHR(30H + 914400 DIV (100 * P.Unit));
		name[i+4] := "."; name[i+5] := "F"; name[i+6] := "n"; name[i+7] := "t";
		name[i+8] := 0X;
		metric := Fonts.This(name);
		IF metric.type = Fonts.substitute THEN metric := NIL END;
		RETURN metric
	END GetMetric;

 PROCEDURE NewPrinter*(): Printer.Printer;
  VAR P: PSPrinter;
  BEGIN
	NEW(P);
	P.name := "PSPrinter.Install";
	P.InitMetrics := InitMetrics;
	P.Escape := Escape;
	P.Open := Open;
	P.Close := Close;
	P.Page := Page;
	P.ReplConst := ReplConst;
	P.ReplPattern := ReplPattern;
	P.Line := Line;
	P.Circle := Circle;
	P.Ellipse := Ellipse;
	P.Spline := Spline;
	P.Picture := Picture;
	P.UseListFont := UseListFont;
	P.String := String;
	P.ContString := ContString;
	P.UseColor := UseColor;
	P.GetMetric := GetMetric;
	RETURN P
  END NewPrinter;

  PROCEDURE Install*;
  BEGIN Printer.Install(NewPrinter());
  END Install;

	PROCEDURE Init;
		VAR class: Objects.Name; size: LONGINT; style: SET;
	BEGIN
		ParseName(Fonts.Default.name, default, size, style, class)
	END Init;

	PROCEDURE Cleanup;
	BEGIN
		IF (Printer.current # NIL) & (Printer.current IS PSPrinter) THEN
			Printer.current := NIL
		END
	END Cleanup;

BEGIN
	hexArray := "0123456789ABCDEF";
	metric := NIL; Init();
	Modules.InstallTermHandler(Cleanup)
END PSPrinter.



	System.Free PSPrinter ~
	PSPrinter.Install

	EmptyPrinter.Install

	System.Free EamonPrinter LPRPrinter PSPrinter ~
	LPRPrinter.Install
