lappend auto_path "./vendor"

package require http 2.9
package require tls 1.7
package require json

http::register https 443 [list ::tls::socket -autoservername true]

set request [http::geturl "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-bdfm" \
                 -method GET \
                 -headers [list x-api-key XXX]]
set data [http::data $request]

set cc [c create]
$cc cflags -I. -I./vendor/nanopb ./vendor/nanopb/pb_common.c ./vendor/nanopb/pb_decode.c  ./play/gtfs-realtime.pb.c
$cc include <pb_decode.h>
$cc include "play/gtfs-realtime.pb.h"
$cc proc decode {char* buf size_t bufsz} void {
    transit_realtime_FeedMessage ev = transit_realtime_FeedMessage_init_zero;
    pb_istream_t stream = pb_istream_from_buffer((pb_byte_t *)buf, bufsz);
    pb_decode(&stream, transit_realtime_FeedMessage_fields, &ev);
    printf("Message: version: %s\n", ev.header.gtfs_realtime_version);
}
$cc compile

decode $data [string length $data]
