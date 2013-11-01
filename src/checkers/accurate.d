/+
  Copyright (C) 2013 Karsten Heinze <karsten@sidenotes.de>

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program. If not, see <http://www.gnu.org/licenses/>.
+/

module checkers.accurate;

import core.exception;
import std.c.string;
import std.exception;
import std.math;
import std.random;
import std.signals;
import std.stdio;
import std.stream;

import c.cdio.sector;
import c.cdio.types;
import checkers.base;
import introspection;
import log;
import media;
import utils;


/**
 * The disc identifier used by accurate rip.
 */
struct DiscIdent
{
    ubyte tracks;
    uint  trackOffsetsSum;
    uint  trackOffsetsProduct;
    uint  cddbDiscId;

    this( in ubyte[] data )
    {
        tracks = data[ 0 ];

        // FIXME: Works only on LE systems.
        memcpy( &trackOffsetsSum, &( data[ 1 ] ), trackOffsetsSum.sizeof );
        memcpy( &trackOffsetsProduct, &( data[ 5 ] ), trackOffsetsProduct.sizeof );
        memcpy( &cddbDiscId, &( data[ 9 ] ), cddbDiscId.sizeof );
    }

    bool opEquals( T ) ( auto ref T other )
    {
        return tracks == other.tracks &&
               trackOffsetsSum == other.trackOffsetsSum &&
               trackOffsetsProduct == other.trackOffsetsProduct &&
               cddbDiscId == other.cddbDiscId;
    }
}

/**
 * The track data used by accurate rip.
 */
struct TrackData
{
    ubyte confidence;
    uint  crc;
    int   offset;

    this( in ubyte[] data )
    {
        confidence = data[ 0 ];

        // FIXME: Works only on LE systems.
        memcpy( &crc, &( data[ 1 ] ), crc.sizeof );
        memcpy( &offset, &( data[ 5 ] ), offset.sizeof );
    }
}

/**
 * The track CRC data.
 */
struct CrcData
{
    uint factor = 1;
    uint crc;
}

/**
 * The accurate check data of a track.
 */
struct AccurateCheckData
{
    Disc  disc;
    ubyte track; // starts with 1
    bool  isLastTrack = false;
    CrcData[ int ] crcByOffset;
    string    url;
    DiscIdent discIdent;

    this( Disc d, ubyte t )
    {
        disc  = d;
        track = t;

        // Is last track?
        Track[] tracks = d.tracks();
        foreach_reverse ( elem; tracks )
        {
            if ( !elem.isAudio() )
            {
                continue;
            }

            if ( elem.number() == track )
            {
                isLastTrack = true;
            }
            break;
        }

        // Calc DiscIdent and URL.
        const string BASE_URL = "http://www.accuraterip.com";
        lsn_t        tmp;
        uint         trackOffsetsSum;
        uint         trackOffsetsProduct;
        string       trackOffsetsSumAsHexString;

        // NOTE: lsn is lba in libcdio, see this discussion:
        //   http://lists.gnu.org/archive/html/libcdio-devel/2012-11/msg00010.html
        foreach ( i, track; tracks )
        {
            tmp                  = track.sectorRange.from;
            trackOffsetsSum     += tmp;
            trackOffsetsProduct += ( ( tmp != 0 ? tmp : 1 ) * ( i + 1 ) );
        }
        // Lead out too.
        tmp                        = tracks[ $ - 1 ].sectorRange.to + 1;
        trackOffsetsSum           += tmp;
        trackOffsetsProduct       += ( ( tmp != 0 ? tmp : 1 ) * ( tracks.length + 1 ) );
        trackOffsetsSumAsHexString = format( "%08x", trackOffsetsSum );

        // Set members.
        discIdent.tracks              = cast( ubyte )tracks.length;
        discIdent.trackOffsetsSum     = trackOffsetsSum;
        discIdent.trackOffsetsProduct = trackOffsetsProduct;
        discIdent.cddbDiscId          = media.cddbDiscId( disc );

        url = format(
            "%s/accuraterip/%c/%c/%c/dBAR-%03d-%08x-%08x-%08x.bin",
            BASE_URL,
            trackOffsetsSumAsHexString[ 7 ],
            trackOffsetsSumAsHexString[ 6 ],
            trackOffsetsSumAsHexString[ 5 ],
            tracks.length,
            trackOffsetsSum,
            trackOffsetsProduct,
            discIdent.cddbDiscId
            );
    }
}

/**
 * An instance of this class is used to check
 * wether tracks were ripped accurately.
 *
 * http://accuraterip.com
 */
class AccurateChecker : Checker
{
private:
    /** known sample offsets */
    static int[] OFFSETS = [
            -582,
            0,
            6,
            12,
            48,
            91,
            97,
            102,
            108,
            120,
            564,
            594,
            667,
            685,
            691,
            704,
            738,
            1194,
            1292,
            1336,
            1776
        ];

    /** accurate check data by id */
    AccurateCheckData[ ulong ] _data;

    /** offset of the underlying source */
    int _offset;

    /** is underlying source calibrated */
    bool _calibrated;

public:
    ulong init( Disc disc, in ubyte track )
    {
        // Generate random id as lookup key.
        ulong id = uniform!( ulong )();

        AccurateCheckData data = AccurateCheckData( disc, track );
        foreach ( offset; OFFSETS )
        {
            data.crcByOffset[ offset ] = CrcData();
        }
        _data[ id ] = data;
        return id;
    }

    void feed(
        in ulong id,
        in lsn_t sector,
        in ubyte[][ SECTORS_TO_READ ] data
        )
    {
        try
        {
            AccurateCheckData d = _data[ id ];

            // Ignore first 5 sectors of disc (except last byte of 5th sector) and
            // last 5 sectors of disc (consider only audio tracks).
            bool ignore = (
                ( d.track == 1 && sector < 5 ) ||
                ( d.isLastTrack && sector > ( d.disc.tracks[ d.track - 1 ].sectorRange().to - 5 ) )
                );


            foreach ( offset; OFFSETS )
            {
                CrcData crcData = d.crcByOffset[ offset ];

                // Prepare buffers covering sector.
                // Two buffers covering CDIO_CD_FRAMESIZE_RAW bytes are returned.
                ulong     byteOffset = SAMPLE_SIZE * offset;
                ubyte[][] buffers;
                while ( length( buffers ) < CDIO_CD_FRAMESIZE_RAW )
                {
                    if ( !buffers.length )
                    {
                        buffers ~= cast( ubyte[] )data
                        [ ( MAX_SECTORS_OFFSET * CDIO_CD_FRAMESIZE_RAW +
                            byteOffset ) / CDIO_CD_FRAMESIZE_RAW ]
                        [ ( MAX_SECTORS_OFFSET * CDIO_CD_FRAMESIZE_RAW +
                            byteOffset ) % CDIO_CD_FRAMESIZE_RAW .. $ ];
                    }
                    else
                    {
                        buffers ~= cast( ubyte[] )data
                        [ ( MAX_SECTORS_OFFSET * CDIO_CD_FRAMESIZE_RAW +
                            byteOffset + length( buffers ) ) / CDIO_CD_FRAMESIZE_RAW ]
                        [ 0 .. CDIO_CD_FRAMESIZE_RAW - length( buffers ) ];
                    }
                }

                // Now calc the checksum.
                uint  tmp;
                ubyte read;
                foreach ( i, buffer; buffers )
                {
                    foreach ( k, elem; buffer )
                    {
                        ++read;

                        // Handle sector.
                        if ( !ignore )
                        {
                            *( cast( ubyte* )( &tmp ) + read - 1 ) = elem;

                            if ( read == 4 )
                            {
                                crcData.crc += ( crcData.factor * tmp );
                            }
                        }
                        // Also handle last sample of 5th sector,
                        // which is found at the end of second buffer.
                        else if ( sector == 4 && i == ( buffers.length - 1 ) && k >= ( buffer.length - 4 ) )
                        {
                            // FIXME: Byte order save!
                            *( cast( ubyte* )( &tmp ) + read - 1 ) = elem;

                            if ( read == 4 )
                            {
                                crcData.crc += ( crcData.factor * tmp );
                            }
                        }

                        if ( read == 4 )
                        {
                            ++( crcData.factor );
                            read = 0;
                        }
                    }
                }

                // Store crcData, because structs are copied by value!
                d.crcByOffset[ offset ] = crcData;
            }

            // Store d, because structs are copied by value!
            _data[ id ] = d;
        }
        catch ( RangeError e )
        {
            // Log a range violation.
            logError( format(
                    "either check %ul was not found or track is not part of disc", id
                    ) );
        }
    }

    bool finish( in ulong id, out string result )
    {
        try
        {
            // TODO: lookup in accurate rip db and cleanup
            AccurateCheckData d = _data[ id ];
            result = "";
            TrackData[] matches;
            foreach ( offset; OFFSETS )
            {
                //result ~= format( "\naccurate rip calculated crc of 0x%08x for disc 0x%08x (offset %d)",
                //    d.crcByOffset[ offset ].crc, d.discIdent.cddbDiscId, offset );
                //result ~= format( "\n%s", d.url );

                ubyte dbuffer[ 13 ];  // don't use DiscIdent.sizeof because of alignment
                ubyte tbuffer[ 9 ];   // don't use TrackData.sizeof because of alignment

                std.stream.File file = new std.stream.File( "dBAR-019-0037354d-03051d36-1612b213.bin" );
                //std.stream.File file = new std.stream.File( "dBAR-010-0010aad4-0085d1ed-7d0acb0a.bin" );

                bool match;
                while ( !file.eof )
                {
                    file.readExact( &dbuffer, dbuffer.sizeof );

                    DiscIdent discIdent = DiscIdent( dbuffer );
                    match = ( discIdent == d.discIdent );
                    for ( uint i = 0; i < discIdent.tracks; ++i )
                    {
                        file.readExact( &tbuffer, tbuffer.sizeof );

                        if ( match && ( i + 1 ) == d.track )
                        {
                            TrackData trackData = TrackData( tbuffer );
                            if ( d.crcByOffset[ offset ].crc == trackData.crc )
                            {
                                // FIXME: Offset in files seems to be wrong, so overwrite!
                                trackData.offset = offset;
                                matches ~= trackData;
                            }
                        }
                    }
                }
            }

            if ( matches.length == 1 )
            {
                result ~= format( "track %d was ripped accurately with offset %d and confidence %d",
                    d.track, matches[ 0 ].offset, matches[ 0 ].confidence );

                _offset = matches[ 0 ].offset;
                _calibrated = true;
            }
            else if ( matches.length == 0 )
            {
                result ~= format( "track %d wasn't ripped accurately", d.track );
            }
            else
            {
                result ~= format( "track %d was ripped accurately, but offset is not clear", d.track );
            }

            return ( matches.length == 1 );
        }
        catch ( RangeError e )
        {
            result = format( "check %ul was not found", id );
            return false;
        }
        catch ( ErrnoException e )
        {
            result = "failed to open file";
            return false;
        }
        catch ( ReadException e )
        {
            result = "failed to read from file";
            return false;
        }
    }

    bool isCalibrated()
    {
        return _calibrated;
    }

    int getOffset()
    {
        return _offset;
    }

    mixin introspection.Initial;
    mixin Log;
}

