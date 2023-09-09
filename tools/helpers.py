def count_indentation_and_strip(line: str) -> tuple[int, str]:
    """Count the levels of indentation (increments of 4 spaces) and strip the indentation"""
    if not line.startswith(" "):
        return 0, line

    level = 0
    for char in line:
        if char == " ":
            level += 0.25
        elif char == "\t":
            level += 1
        else:
            break

    return round(level), line.strip()


def count_comment_level_and_strip(line: str) -> tuple[int, str]:
    if not line.startswith("#"):
        return 0, line
    
    level = 0
    for char in line:
        if char == "#": level += 1
        else: break
    
    return level, line[level:].strip()