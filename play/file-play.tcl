# create some data
set data "\n#=== editing ===\n\nThis is some test data.\n"
# pick a filename - if you don't include a path,
#  it will be saved in the current directory
set filename "~/code/folk/virtual-programs/label.folk"
# open the filename for writing
set fileId [open $filename r+]

set fileBeforeEditing [read $fileId]
puts $fileBeforeEditing

# send the data to the file -
#  omitting '-nonewline' will result in an extra newline
# at the end of the file
puts -nonewline $fileId $data

set fileAfterEditing [read $fileId]
puts $fileAfterEditing

# close the file, ensuring the data is written out before you continue
#  with processing.
close $fileId