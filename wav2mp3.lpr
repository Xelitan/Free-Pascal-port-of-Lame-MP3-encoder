{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
program wav2mp3;

// Minimal WAV-PCM to MP3 encoder using the LAME Pascal translation.
// Usage: wav2mp3 input.wav output.mp3
// Fixed settings: 128 kbit/s CBR, stereo (or mono if WAV is mono),
//                 sample rate taken from the WAV header.
// License: GNU LGPL
// Author: www.xelitan.com

uses
  SysUtils, Classes,
  LameTypes, LameCore, LameVbrTag;

// -----------------------------------------------------------------------
//  WAV header parser
//  ----------------------------------------------------------------------- 

type
  TWavHeader = packed record
    ChunkID:       array[0..3] of AnsiChar; { "RIFF" }
    ChunkSize:     Cardinal;
    Format:        array[0..3] of AnsiChar; { "WAVE" }
    Subchunk1ID:   array[0..3] of AnsiChar; { "fmt " }
    Subchunk1Size: Cardinal;
    AudioFormat:   Word;                    // 1 = PCM
    NumChannels:   Word;
    SampleRate:    Cardinal;
    ByteRate:      Cardinal;
    BlockAlign:    Word;
    BitsPerSample: Word;
  end;

// Read the fmt chunk and locate the data chunk.
//  Returns True on success; DataSize receives the byte count of PCM data.
function ReadWavHeader(f: TFileStream; out hdr: TWavHeader; out DataSize: Cardinal): Boolean;
var
  tag:  array[0..3] of AnsiChar;
  size: Cardinal;
begin
  Result := False;

  if f.Read(hdr, SizeOf(hdr)) <> SizeOf(hdr) then Exit;

  if (hdr.ChunkID <> 'RIFF') or (hdr.Format <> 'WAVE') then Exit;
  if hdr.Subchunk1ID <> 'fmt ' then Exit;
  if hdr.AudioFormat <> 1 then
  begin
    WriteLn('Error: only uncompressed PCM WAV is supported.');
    Exit;
  end;
  if not (hdr.BitsPerSample in [8, 16]) then
  begin
    WriteLn('Error: only 8-bit and 16-bit PCM are supported.');
    Exit;
  end;

  // Skip any extra fmt bytes beyond the standard 16
  if hdr.Subchunk1Size > 16 then
    f.Seek(hdr.Subchunk1Size - 16, soCurrent);

  // Scan for the "data" chunk
  DataSize := 0;
  while f.Position < f.Size - 8 do
  begin
    if f.Read(tag,  SizeOf(tag))  <> SizeOf(tag)  then Exit;
    if f.Read(size, SizeOf(size)) <> SizeOf(size) then Exit;
    if tag = 'data' then
    begin
      DataSize := size;
      Result := True;
      Exit;
    end;
    f.Seek(size, soCurrent);  //skip unknown chunk
  end;
end;


const
  PCM_CHUNK   = 1152;          // samples per channel per MPEG frame 
  MP3_BUFSIZE = PCM_CHUNK * 5; // generous MP3 output buffer 

var
  wavFile, mp3File: TFileStream;
  wavHdr:   TWavHeader;
  dataSize: Cardinal;
  gfp:      PLameGlobalFlags;

  //PCM read buffers
  rawBuf:  array of Byte;       //interleaved bytes from flie
  pcmL:    array of SmallInt;
  pcmR:    array of SmallInt;
  mp3Buf:  array[0..MP3_BUFSIZE - 1] of Byte;

  bytesPerSample: Integer;
  bytesPerFrame:  Integer;       //bytes for PCM_CHUNK frames, all channels
  bytesRead:      Integer;
  samplesRead:    Integer;
  mp3Bytes:       Integer;
  i:              Integer;
  s8:             ShortInt;
  totalMp3:       Int64;
begin
  if ParamCount <> 2 then
  begin
    WriteLn('Usage: wav2mp3 input.wav output.mp3');
    Halt(1);
  end;

  try
    wavFile := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
  except
    WriteLn('Error: cannot open "', ParamStr(1), '"');
    Halt(1);
  end;

  try
    mp3File := TFileStream.Create(ParamStr(2), fmCreate);
  except
    wavFile.Free;
    WriteLn('Error: cannot create "', ParamStr(2), '"');
    Halt(1);
  end;

  //Parse WAV header
  if not ReadWavHeader(wavFile, wavHdr, dataSize) then
  begin
    WriteLn('Error: invalid or unsupported WAV file.');
    wavFile.Free;
    mp3File.Free;
    Halt(1);
  end;

  Writeln('WAV: ', wavHdr.SampleRate, ' Hz, ',
          wavHdr.NumChannels, ' ch, ',
          wavHdr.BitsPerSample, '-bit PCM, ',
          dataSize div wavHdr.BlockAlign, ' samples');

  //Initialise LAME
  gfp := lame_init;
  if gfp = nil then
  begin
    WriteLn('Error: lame_init failed.');
    wavFile.Free;
    mp3File.Free;
    Halt(1);
  end;

  gfp^.samplerate_in  := wavHdr.SampleRate;
  gfp^.samplerate_out := 0;          // 0 = same as input }
  gfp^.num_channels   := wavHdr.NumChannels;
  gfp^.brate          := 128;
  gfp^.VBR            := vbr_off;    // CBR }
  gfp^.quality        := 5;          // 2=highest, 7=fastest, 5=default }
  gfp^.write_lame_tag := 1;          // embed Info tag }
  if wavHdr.NumChannels = 1 then
    gfp^.mode := MONO
  else
    gfp^.mode := JOINT_STEREO;

  if lame_init_params(gfp) < 0 then
  begin
    WriteLn('Error: lame_init_params failed (unsupported sample rate or bitrate?).');
    lame_close(gfp);
    wavFile.Free;
    mp3File.Free;
    Halt(1);
  end;

  // Write the Info-tag placeholder frame 
  if InitVbrTag(gfp) < 0 then
  begin
    WriteLn('Warning: could not allocate VBR seek table; Info tag disabled.');
    gfp^.write_lame_tag := 0;
  end;

  // Encode loop
  bytesPerSample := wavHdr.BitsPerSample div 8;
  bytesPerFrame  := PCM_CHUNK * Integer(wavHdr.NumChannels) * bytesPerSample;
  SetLength(rawBuf, bytesPerFrame);
  SetLength(pcmL,   PCM_CHUNK);
  SetLength(pcmR,   PCM_CHUNK);

  totalMp3 := 0;

  while wavFile.Position < Int64(wavFile.Size) do
  begin
    bytesRead   := wavFile.Read(rawBuf[0], bytesPerFrame);
    samplesRead := bytesRead div (Integer(wavHdr.NumChannels) * bytesPerSample);

    if samplesRead <= 0 then Break;

    //Deinterleave raw bytes → signed 16-bit channel arrays 
    if wavHdr.BitsPerSample = 16 then
    begin
      if wavHdr.NumChannels >= 2 then
      begin
        for i := 0 to samplesRead - 1 do
        begin
          pcmL[i] := PSmallInt(@rawBuf[i * 4])^;
          pcmR[i] := PSmallInt(@rawBuf[i * 4 + 2])^;
        end;
      end
      else
      begin
        for i := 0 to samplesRead - 1 do
        begin
          pcmL[i] := PSmallInt(@rawBuf[i * 2])^;
          pcmR[i] := pcmL[i];
        end;
      end;
    end
    else
    begin
      // 8-bit PCM: unsigned 0..255, centre = 128 → signed 
      if wavHdr.NumChannels >= 2 then
      begin
        for i := 0 to samplesRead - 1 do
        begin
          s8 := ShortInt(Integer(rawBuf[i * 2])     - 128);
          pcmL[i] := SmallInt(s8) * 256;
          s8 := ShortInt(Integer(rawBuf[i * 2 + 1]) - 128);
          pcmR[i] := SmallInt(s8) * 256;
        end;
      end
      else
      begin
        for i := 0 to samplesRead - 1 do
        begin
          s8 := ShortInt(Integer(rawBuf[i]) - 128);
          pcmL[i] := SmallInt(s8) * 256;
          pcmR[i] := pcmL[i];
        end;
      end;
    end;

    mp3Bytes := lame_encode_buffer(gfp,
                                    @pcmL[0], @pcmR[0], samplesRead,
                                    @mp3Buf[0], SizeOf(mp3Buf));
    if mp3Bytes < 0 then
    begin
      WriteLn('Error: lame_encode_buffer returned ', mp3Bytes);
      Break;
    end;

    if mp3Bytes > 0 then
    begin
      mp3File.Write(mp3Buf[0], mp3Bytes);
      AddVbrFrame(gfp^.internal_flags);
      Inc(totalMp3, mp3Bytes);
    end;
  end;

  // Flush remaining frames 
  mp3Bytes := lame_encode_flush(gfp, @mp3Buf[0], SizeOf(mp3Buf));
  if mp3Bytes > 0 then
  begin
    mp3File.Write(mp3Buf[0], mp3Bytes);
    Inc(totalMp3, mp3Bytes);
  end;

  // Write final Info tag
  if gfp^.write_lame_tag <> 0 then
    PutVbrTag(gfp, mp3File);

  WriteLn('Done. MP3 size: ', totalMp3, ' bytes → "', ParamStr(2), '"');

  // Cleanup 
  lame_close(gfp);
  mp3File.Free;
  wavFile.Free;
end.
