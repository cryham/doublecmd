{
   Double Commander
   -------------------------------------------------------------------------
   High Efficiency Image reader implementation (via libheif)

   Copyright (C) 2021-2024 Alexander Koblov (alexx2000@mail.ru)

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this program. If not, see <http://www.gnu.org/licenses/>.
}

unit uDCReadHEIF;

{$mode delphi}
{$packrecords c}
{$packenum 4}

interface

uses
  Classes, SysUtils, Graphics, FPImage;

type

  { TDCReaderHEIF }

  TDCReaderHEIF = class (TFPCustomImageReader)
  private
    FContext: Pointer;
  protected
    function  InternalCheck (Stream: TStream): boolean;override;
    procedure InternalRead({%H-}Stream: TStream; Img: TFPCustomImage);override;
  public
    constructor Create; override;
    destructor Destroy; override;
  end;

  { THighEfficiencyImage }

  THighEfficiencyImage = class(TFPImageBitmap)
  protected
    class function GetReaderClass: TFPCustomImageReaderClass; override;
    class function GetSharedImageClass: TSharedRasterImageClass; override;
  public
    class function GetFileExtensions: string; override;
  end;

implementation

uses
  DynLibs, IntfGraphics, GraphType, Types, CTypes, LazUTF8, DCOSUtils, uDebug;

const
  HEIF_EXT = 'heif;heic;avif';

type

  Theif_error_code =
  (
    heif_error_Ok = 0,
    heif_error_Input_does_not_exist = 1,
    heif_error_Invalid_input = 2,
    heif_error_Unsupported_filetype = 3,
    heif_error_Unsupported_feature = 4,
    heif_error_Usage_error = 5,
    heif_error_Memory_allocation_error = 6,
    heif_error_Decoder_plugin_error = 7,
    heif_error_Encoder_plugin_error = 8,
    heif_error_Encoding_error = 9,
    heif_error_Color_profile_does_not_exist = 10
  );

  Theif_colorspace =
  (
    heif_colorspace_YCbCr = 0,
    heif_colorspace_RGB = 1,
    heif_colorspace_monochrome = 2,
    heif_colorspace_undefined = 99
  );

  Theif_channel =
  (
    heif_channel_Y = 0,
    heif_channel_Cb = 1,
    heif_channel_Cr = 2,
    heif_channel_R = 3,
    heif_channel_G = 4,
    heif_channel_B = 5,
    heif_channel_Alpha = 6,
    heif_channel_interleaved = 10
  );

  Theif_chroma =
  (
    heif_chroma_monochrome = 0,
    heif_chroma_420 = 1,
    heif_chroma_422 = 2,
    heif_chroma_444 = 3,
    heif_chroma_interleaved_RGB = 10,
    heif_chroma_interleaved_RGBA = 11,
    heif_chroma_interleaved_RRGGBB_BE = 12,
    heif_chroma_interleaved_RRGGBBAA_BE = 13,
    heif_chroma_interleaved_RRGGBB_LE = 14,
    heif_chroma_interleaved_RRGGBBAA_LE = 15,
    heif_chroma_undefined = 99
  );

  Theif_context = record end;
  Pheif_context = ^Theif_context;

  Theif_error = record
    code: Theif_error_code;
    subcode: UInt32;
    message: PAnsiChar;
  end;

  Pheif_decoding_options = ^Theif_decoding_options;
  Theif_decoding_options = record
    version: cuint8;
    ignore_transformations: cuint8;
    start_progress: pointer;
    on_progress: pointer;
    end_progress: pointer;
    progress_user_data: pointer;
    // version 2 options
    convert_hdr_to_8bit: cuint8;
  end;

var
  heif_context_alloc: function(): Pheif_context; cdecl;
  heif_context_free: procedure(context: Pheif_context); cdecl;

  heif_decoding_options_alloc: function(): Pheif_decoding_options; cdecl;
  heif_decoding_options_free: procedure(options: Pheif_decoding_options); cdecl;

  heif_context_read_from_memory_without_copy: function(context: Pheif_context;
                                                       mem: Pointer; size: csize_t;
                                                       options: Pointer): Theif_error; cdecl;

  heif_context_get_primary_image_handle: function(ctx: Pheif_context;
                                                  image_handle: PPointer): Theif_error; cdecl;
  heif_image_handle_release: procedure(heif_image_handle: Pointer); cdecl;

  heif_image_handle_has_alpha_channel: function(image_handle: Pointer): cint; cdecl;

  heif_decode_image: function(in_handle: Pointer; out_img: PPointer;
                              colorspace: Theif_colorspace; chroma: Theif_chroma;
                              options: Pointer): Theif_error; cdecl;
  heif_image_release: procedure(heif_image: Pointer); cdecl;

  heif_image_get_width: function(heif_image: Pointer; channel: Theif_channel): cint; cdecl;
  heif_image_get_height: function(heif_image: Pointer; channel: Theif_channel): cint; cdecl;

  heif_image_get_plane_readonly: function(heif_image: Pointer;
                                          channel: Theif_channel;
                                          out_stride: pcint): pcuint8; cdecl;

{ THighEfficiencyImage }

class function THighEfficiencyImage.GetReaderClass: TFPCustomImageReaderClass;
begin
  Result:= TDCReaderHEIF;
end;

class function THighEfficiencyImage.GetSharedImageClass: TSharedRasterImageClass;
begin
  Result:= TSharedBitmap;
end;

class function THighEfficiencyImage.GetFileExtensions: string;
begin
  Result:= HEIF_EXT;
end;

{ TDCReaderHEIF }

function TDCReaderHEIF.InternalCheck(Stream: TStream): boolean;
var
  Err: Theif_error;
  MemoryStream: TMemoryStream;
begin
  Result:= Stream is TMemoryStream;
  if Result then
  begin
    MemoryStream:= TMemoryStream(Stream);
    Err:= heif_context_read_from_memory_without_copy(FContext, MemoryStream.Memory, MemoryStream.Size, nil);
    Result:= (Err.code = heif_error_Ok);
  end;
end;

procedure TDCReaderHEIF.InternalRead(Stream: TStream; Img: TFPCustomImage);
var
  Y: cint;
  Alpha: cint;
  ASize: cint;
  AData: PByte;
  ADelta: cint;
  AStride: cint;
  ATarget: PByte;
  Err: Theif_error;
  Chroma: Theif_chroma;
  AWidth, AHeight: cint;
  AImage: Pointer = nil;
  AHandle: Pointer = nil;
  AOptions: Pheif_decoding_options;
  Description: TRawImageDescription;
begin
  Err:= heif_context_get_primary_image_handle(FContext, @AHandle);
  if (Err.code <> heif_error_Ok) then raise Exception.Create(Err.message);

  try
    // Library works wrong with some images from
    // https://github.com/link-u/avif-sample-images
    // when decode image into RGB, but it works fine with RGBA
    Alpha:= 1; // heif_image_handle_has_alpha_channel(AHandle);

    if (Alpha <> 0) then
      Chroma:= heif_chroma_interleaved_RGBA
    else begin
      Chroma:= heif_chroma_interleaved_RGB;
    end;

    AOptions:= heif_decoding_options_alloc();
    try
      if AOptions^.version > 1 then
      begin
        AOptions^.convert_hdr_to_8bit:= 1;
      end;
      Err:= heif_decode_image(AHandle, @AImage, heif_colorspace_RGB, Chroma, AOptions);
    finally
      heif_decoding_options_free(AOptions);
    end;
    if (Err.code <> heif_error_Ok) then raise Exception.Create(Err.message);

    try
      AWidth:= heif_image_get_width(AImage, heif_channel_interleaved);
      AHeight:= heif_image_get_height(AImage, heif_channel_interleaved);
      AData:= heif_image_get_plane_readonly(AImage, heif_channel_interleaved, @AStride);

      if (AData = nil) then raise Exception.Create(EmptyStr);

      if (Alpha <> 0) then
      begin
        ASize:= 4;
        Description.Init_BPP32_R8G8B8A8_BIO_TTB(AWidth, AHeight)
      end
      else begin
        ASize:= 3;
        Description.Init_BPP24_R8G8B8_BIO_TTB(AWidth, AHeight);
      end;
      ADelta:= AStride - AWidth * ASize;
      TLazIntfImage(Img).DataDescription:= Description;

      if ADelta = 0 then
        // We can transfer the whole image at once
        Move(AData^, TLazIntfImage(Img).PixelData^, AStride * AHeight)
      else begin
        AStride:= AWidth * ASize;
        ATarget:= TLazIntfImage(Img).PixelData;
        // Stride has some padding, we have to send the image line by line
        for Y:= 0 to AHeight - 1 do
        begin
          Move(AData^, ATarget[Y * AStride], AStride);
          Inc(AData, AStride + ADelta)
        end;
      end;
    finally
      heif_image_release(AImage);
    end;
  finally
    heif_image_handle_release(AHandle);
  end;
end;

constructor TDCReaderHEIF.Create;
begin
  inherited Create;
  FContext:= heif_context_alloc();
end;

destructor TDCReaderHEIF.Destroy;
begin
  inherited Destroy;
  if Assigned(FContext) then heif_context_free(FContext);
end;

const
{$IF DEFINED(UNIX)}
  heiflib   = 'libheif.so.1';
{$ELSEIF DEFINED(MSWINDOWS)}
  heiflib   = 'libheif.dll';
{$ENDIF}

var
  libheif: TLibHandle;

procedure Initialize;
var
  AVersion: cint;
  AOptions: Pheif_decoding_options;
begin
  libheif:= mbLoadLibraryEx(heiflib);

  if (libheif <> NilHandle) then
  try
    @heif_context_alloc:= SafeGetProcAddress(libheif, 'heif_context_alloc');
    @heif_context_free:= SafeGetProcAddress(libheif, 'heif_context_free');
    @heif_decode_image:= SafeGetProcAddress(libheif, 'heif_decode_image');
    @heif_image_release:= SafeGetProcAddress(libheif, 'heif_image_release');
    @heif_image_get_width:= SafeGetProcAddress(libheif, 'heif_image_get_width');
    @heif_image_get_height:= SafeGetProcAddress(libheif, 'heif_image_get_height');
    @heif_image_handle_release:= SafeGetProcAddress(libheif, 'heif_image_handle_release');
    @heif_decoding_options_free:= SafeGetProcAddress(libheif, 'heif_decoding_options_free');
    @heif_decoding_options_alloc:= SafeGetProcAddress(libheif, 'heif_decoding_options_alloc');
    @heif_image_get_plane_readonly:= SafeGetProcAddress(libheif, 'heif_image_get_plane_readonly');
    @heif_image_handle_has_alpha_channel:= SafeGetProcAddress(libheif, 'heif_image_handle_has_alpha_channel');
    @heif_context_get_primary_image_handle:= SafeGetProcAddress(libheif, 'heif_context_get_primary_image_handle');
    @heif_context_read_from_memory_without_copy:= SafeGetProcAddress(libheif, 'heif_context_read_from_memory_without_copy');

    AOptions:= heif_decoding_options_alloc();
    AVersion:= AOptions^.version;
    heif_decoding_options_free(AOptions);

    if (AVersion < 2) then
    begin
      FreeLibrary(libheif);
      libheif:= NilHandle;
    end
    else begin
      // Register image handler and format
      ImageHandlers.RegisterImageReader ('High Efficiency Image', HEIF_EXT, TDCReaderHEIF);
      TPicture.RegisterFileFormat(HEIF_EXT, 'High Efficiency Image', THighEfficiencyImage);
    end;
  except
    on E: Exception do DCDebug(E.Message);
  end;
end;

procedure Finalize;
begin
  if (libheif <> NilHandle) then FreeLibrary(libheif);
end;

initialization
  Initialize;

finalization
  Finalize;

end.

