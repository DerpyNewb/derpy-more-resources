"""Read installed campaign pathfinding for Resource Overhaul's terrain routes.

    py tools/campaign_route_paths.py --selftest

PPD v2 layout: CampaignMapToolkit/FileFormatDefinitions/010_hex_editor_pathfinding_ppd_template.bt.
This reads map assets; it never replaces them or deploys a pack.
"""
import struct
import sys
import heapq
import zlib


# PPD directions are flat-top, offset by column parity; Y grows northward.
DIRECTIONS = (((0, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0)),
              ((0, 1), (1, 1), (1, 0), (0, -1), (-1, 0), (-1, 1)))


class Grid:
    def __init__(self, width, height, edges, bridges):
        if width <= 0 or height <= 0 or len(edges) != width * height:
            raise ValueError('invalid campaign grid dimensions')
        self.width, self.height, self.edges, self.bridges = width, height, edges, bridges

    def index(self, point):
        x, y = point
        return y * self.width + x if 0 <= x < self.width and 0 <= y < self.height else None

    def neighbours(self, point):
        index = self.index(point)
        if index is None:
            return
        x, y = point
        for direction, (dx, dy) in enumerate(DIRECTIONS[x & 1]):
            target = (x + dx, y + dy)
            other = self.index(target)
            if (other is not None and self.edges[index] & (1 << direction)
                    and self.edges[other] & (1 << ((direction + 3) % 6))):
                yield target
        yield from self.bridges.get(point, ())

    def connected(self, a, b):
        return b in self.neighbours(a)

    def path(self, start, end, limit=200000):
        if self.index(start) is None or self.index(end) is None:
            return None
        frontier = [(0, start)]
        costs, previous = {start: 0}, {}
        while frontier and limit > 0:
            _, point = heapq.heappop(frontier)
            limit -= 1
            if point == end:
                path = [point]
                while point in previous:
                    point = previous[point]
                    path.append(point)
                return path[::-1]
            for target in self.neighbours(point):
                cost = costs[point] + max(1, abs(target[0] - point[0]), abs(target[1] - point[1]))
                if cost < costs.get(target, float('inf')):
                    costs[target], previous[target] = cost, point
                    heuristic = max(abs(target[0] - end[0]), abs(target[1] - end[1]))
                    heapq.heappush(frontier, (cost + heuristic, target))
        return None


def read_ppd(data):
    if len(data) < 20 or data[:8] != b'\x89PPD\r\n\x1a\n':
        raise ValueError('not a campaign PPD file')
    if struct.unpack_from('<I', data, 8)[0] != 2:
        raise ValueError('unsupported PPD version')
    if zlib.crc32(data[:-4]) != struct.unpack_from('<I', data, len(data) - 4)[0]:
        raise ValueError('PPD checksum mismatch')
    offset = 12

    def take(fmt):
        nonlocal offset
        values = struct.unpack_from('<' + fmt, data, offset)
        offset += struct.calcsize('<' + fmt)
        return values[0] if len(values) == 1 else values

    regions = []
    for _ in range(take('I')):
        length = take('I')
        regions.append(data[offset:offset + length].decode('ascii'))
        offset += length
    width, height = take('HH')
    cells = data[offset:offset + width * height * 8]
    if len(cells) != width * height * 8:
        raise ValueError('truncated PPD grid')
    offset += len(cells)
    edges = bytearray(width * height)
    for i in range(width * height):
        kind = cells[i * 8 + 7] >> 4
        if kind == 2:
            continue
        edges[i] = sum(1 << d for d in range(6) if cells[i * 8 + d] & 128)
    count = take('I'); offset += count * 2  # movement costs
    count = take('H'); offset += count * 4  # tile groups
    for _ in regions:
        count = take('H'); offset += count * 5
    for _ in range(take('H')):
        offset += 4  # beach HLCI pair
        count = take('H'); offset += count * 5
        count = take('H'); offset += count * 5
    count = take('H'); offset += count * 4  # HLCI connections
    bridges = {}
    for _ in range(take('H')):
        sides = [[take('HH') for _ in range(take('H'))] for _ in range(2)]
        for left, right in (sides, sides[::-1]):
            for point in left:
                bridges.setdefault(point, []).extend(right)
    grid = Grid(width, height, bytes(edges), bridges)
    grid.regions = regions
    return grid


def selftest():
    # A destination two columns east is separated by a blocked direct edge.
    grid = Grid(5, 5, bytes([0] * 25), {})
    assert grid.path((1, 2), (3, 2)) is None
    grid.edges = bytes([63] * 25)
    path = grid.path((1, 2), (3, 2))
    assert path[0] == (1, 2) and path[-1] == (3, 2)
    edges = bytearray(grid.edges)
    # Wall with one gap: reaching the other side must go around its southern end.
    for y in range(1, 5):
        edges[y * 5 + 2] = 0
    grid.edges = bytes(edges)
    path = grid.path((1, 2), (3, 2))
    assert path and (2, 0) in path and (2, 2) not in path
    assert all(grid.connected(a, b) for a, b in zip(path, path[1:]))
    assert grid.path((-1, 2), (3, 2)) is None
    assert grid.path((1, 2), (5, 2)) is None
    assert grid.path((1, 2), (3, 2), limit=1) is None
    try:
        read_ppd(b'not a pathfinding file')
    except ValueError:
        pass
    else:
        raise AssertionError('invalid PPD accepted')
    print('campaign path checks passed: blocked edges, detour, bounds, work limit, bad header')


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest()
    else:
        raise SystemExit(__doc__)
