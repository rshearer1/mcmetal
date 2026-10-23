/* OpenAL 1.1 + ALC 1.1 + EFX types and the enum values mcm_al.m implements (values from the OpenAL 1.1 and EFX
 * specifications; written out here so nothing collides with Apple's deprecated OpenAL.framework headers). */
#pragma once
#include <stddef.h>

typedef char ALboolean;
typedef char ALchar;
typedef signed char ALbyte;
typedef unsigned char ALubyte;
typedef short ALshort;
typedef unsigned short ALushort;
typedef int ALint;
typedef unsigned int ALuint;
typedef int ALsizei;
typedef int ALenum;
typedef float ALfloat;
typedef double ALdouble;
typedef void ALvoid;
typedef char ALCboolean;
typedef char ALCchar;
typedef int ALCint;
typedef unsigned int ALCuint;
typedef int ALCsizei;
typedef int ALCenum;
typedef void ALCvoid;
typedef struct mcm_device ALCdevice;
typedef struct mcm_context ALCcontext;

#define AL_API __attribute__((visibility("default")))

#define AL_NONE 0
#define AL_FALSE 0
#define AL_TRUE 1

/* errors */
#define AL_NO_ERROR 0
#define AL_INVALID_NAME 0xA001
#define AL_INVALID_ENUM 0xA002
#define AL_INVALID_VALUE 0xA003
#define AL_INVALID_OPERATION 0xA004
#define AL_OUT_OF_MEMORY 0xA005
#define ALC_NO_ERROR 0
#define ALC_INVALID_DEVICE 0xA001
#define ALC_INVALID_CONTEXT 0xA002
#define ALC_INVALID_ENUM 0xA003
#define ALC_INVALID_VALUE 0xA004
#define ALC_OUT_OF_MEMORY 0xA005

/* source and listener */
#define AL_SOURCE_RELATIVE 0x202
#define AL_CONE_INNER_ANGLE 0x1001
#define AL_CONE_OUTER_ANGLE 0x1002
#define AL_PITCH 0x1003
#define AL_POSITION 0x1004
#define AL_DIRECTION 0x1005
#define AL_VELOCITY 0x1006
#define AL_LOOPING 0x1007
#define AL_BUFFER 0x1009
#define AL_GAIN 0x100A
#define AL_MIN_GAIN 0x100D
#define AL_MAX_GAIN 0x100E
#define AL_ORIENTATION 0x100F
#define AL_SOURCE_STATE 0x1010
#define AL_INITIAL 0x1011
#define AL_PLAYING 0x1012
#define AL_PAUSED 0x1013
#define AL_STOPPED 0x1014
#define AL_BUFFERS_QUEUED 0x1015
#define AL_BUFFERS_PROCESSED 0x1016
#define AL_REFERENCE_DISTANCE 0x1020
#define AL_ROLLOFF_FACTOR 0x1021
#define AL_CONE_OUTER_GAIN 0x1022
#define AL_MAX_DISTANCE 0x1023
#define AL_SEC_OFFSET 0x1024
#define AL_SAMPLE_OFFSET 0x1025
#define AL_BYTE_OFFSET 0x1026
#define AL_SOURCE_TYPE 0x1027
#define AL_STATIC 0x1028
#define AL_STREAMING 0x1029
#define AL_UNDETERMINED 0x1030

/* buffers */
#define AL_FORMAT_MONO8 0x1100
#define AL_FORMAT_MONO16 0x1101
#define AL_FORMAT_STEREO8 0x1102
#define AL_FORMAT_STEREO16 0x1103
#define AL_FORMAT_MONO_FLOAT32 0x10010
#define AL_FORMAT_STEREO_FLOAT32 0x10011
#define AL_FREQUENCY 0x2001
#define AL_BITS 0x2002
#define AL_CHANNELS 0x2003
#define AL_SIZE 0x2004

/* strings and state */
#define AL_VENDOR 0xB001
#define AL_VERSION 0xB002
#define AL_RENDERER 0xB003
#define AL_EXTENSIONS 0xB004
#define AL_DOPPLER_FACTOR 0xC000
#define AL_DOPPLER_VELOCITY 0xC001
#define AL_SPEED_OF_SOUND 0xC003
#define AL_DISTANCE_MODEL 0xD000
#define AL_INVERSE_DISTANCE 0xD001
#define AL_INVERSE_DISTANCE_CLAMPED 0xD002
#define AL_LINEAR_DISTANCE 0xD003
#define AL_LINEAR_DISTANCE_CLAMPED 0xD004
#define AL_EXPONENT_DISTANCE 0xD005
#define AL_EXPONENT_DISTANCE_CLAMPED 0xD006
#define AL_SOURCE_DISTANCE_MODEL 0x200 /* AL_EXT_source_distance_model */

/* ALC */
#define ALC_FREQUENCY 0x1007
#define ALC_REFRESH 0x1008
#define ALC_SYNC 0x1009
#define ALC_MONO_SOURCES 0x1010
#define ALC_STEREO_SOURCES 0x1011
#define ALC_MAJOR_VERSION 0x1000
#define ALC_MINOR_VERSION 0x1001
#define ALC_ATTRIBUTES_SIZE 0x1002
#define ALC_ALL_ATTRIBUTES 0x1003
#define ALC_DEFAULT_DEVICE_SPECIFIER 0x1004
#define ALC_DEVICE_SPECIFIER 0x1005
#define ALC_EXTENSIONS 0x1006
#define ALC_DEFAULT_ALL_DEVICES_SPECIFIER 0x1012
#define ALC_ALL_DEVICES_SPECIFIER 0x1013
#define ALC_CAPTURE_DEVICE_SPECIFIER 0x310
#define ALC_CAPTURE_DEFAULT_DEVICE_SPECIFIER 0x311
#define ALC_CAPTURE_SAMPLES 0x312
#define ALC_CONNECTED 0x313
#define ALC_HRTF_SOFT 0x1992 /* ALC_SOFT_HRTF */
#define ALC_HRTF_STATUS_SOFT 0x1993
#define ALC_NUM_HRTF_SPECIFIERS_SOFT 0x1994

/* EFX */
#define ALC_EFX_MAJOR_VERSION 0x20001
#define ALC_EFX_MINOR_VERSION 0x20002
#define ALC_MAX_AUXILIARY_SENDS 0x20003
#define AL_METERS_PER_UNIT 0x20004
#define AL_DIRECT_FILTER 0x20005
#define AL_AUXILIARY_SEND_FILTER 0x20006
#define AL_AIR_ABSORPTION_FACTOR 0x20007
#define AL_ROOM_ROLLOFF_FACTOR 0x20008
#define AL_CONE_OUTER_GAINHF 0x20009
#define AL_DIRECT_FILTER_GAINHF_AUTO 0x2000A
#define AL_AUXILIARY_SEND_FILTER_GAIN_AUTO 0x2000B
#define AL_AUXILIARY_SEND_FILTER_GAINHF_AUTO 0x2000C
#define AL_EFFECT_TYPE 0x8001
#define AL_EFFECT_NULL 0x0000
#define AL_EFFECT_REVERB 0x0001
#define AL_EFFECT_EAXREVERB 0x8000
#define AL_FILTER_TYPE 0x8001
#define AL_FILTER_NULL 0x0000
#define AL_FILTER_LOWPASS 0x0001
#define AL_FILTER_HIGHPASS 0x0002
#define AL_FILTER_BANDPASS 0x0003
#define AL_LOWPASS_GAIN 0x0001
#define AL_LOWPASS_GAINHF 0x0002
#define AL_EFFECTSLOT_EFFECT 0x0001
#define AL_EFFECTSLOT_GAIN 0x0002
#define AL_EFFECTSLOT_AUXILIARY_SEND_AUTO 0x0003
#define AL_EFFECTSLOT_NULL 0x0000
/* reverb and EAX reverb parameters (mcm_al.m only reads the gain and decay time) */
#define AL_REVERB_GAIN 0x0003
#define AL_REVERB_DECAY_TIME 0x0005
#define AL_EAXREVERB_GAIN 0x0003
#define AL_EAXREVERB_DECAY_TIME 0x0006
