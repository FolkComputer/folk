import helpers

lines = None

with open("./lib/math.tcl") as doc:
    lines = doc.readlines()

if lines == None:
    print("No lines read")
    exit()

docs = []

for line in lines:
    indention, line = helpers.count_indentation_and_strip(line)
    comment_level, line = helpers.count_comment_level_and_strip(line)
    if comment_level == 3:
        # metadata line
        parse_metadata(line)
    
def parse_metadata(line: str):
    