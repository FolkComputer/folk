proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

set cc [c create]
$cc struct Name {
    char* first;
    char* last;
}
$cc struct Person {
    Name name;
    char* state;
}
$cc proc omar {} Person {
    Person ret = (Person) {
        .name = (Name) { .first = "Omar", .last = "Rizwan" },
        .state = "NJ"
    };
    return ret;
}

$cc compile

puts [omar]
assert {[dict get [omar] name last] eq "Rizwan"}


set c2 [c create]

$c2 struct image_t {
  uint32_t width;
  uint32_t height;
  int components;
  uint32_t bytesPerRow;
  uint8_t* data;
}

$c2 proc imageThereAndBack {image_t im} image_t {
    return im;
}

$c2 compile

set im [ dict create width 1 \
		     height 1 \
		     components 1 \
		     bytesPerRow 1 \
		     data 0x0]

[imageThereAndBack im]
