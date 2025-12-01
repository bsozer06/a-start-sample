# Shortest Path Algorithms: A* Example

## Problem

Imagine a grid:
- Each square is a place
- Some squares are walls
- One square is the start
- One square is the goal

**Goal:** Find the shortest path from start to goal, without hitting walls.

## A* Idea

A* thinks like this:
- "How close am I to the goal if I go here?"
- "How far have I come so far?"

It adds these together and picks the best next step.

## Simple Example

Grid:
```
S . . #
. # . .
. # . G
. . . .
```
S = Start, G = Goal, # = Wall, . = Empty

A* works like this:
1. Looks around from the start
2. Avoids walls
3. Tries squares closer to the goal first
4. Finds the shortest path by trying options

## Heuristic (Estimate to Goal)

We use Manhattan distance:
- How many steps left/right/up/down to reach the goal?

## Neighbors

From each square, you can move:
- Up
- Down
- Left
- Right

## A* Algorithm (Simple)

See the notebook for the code implementation.

## How A* Works

- Picks the smartest square to try next
- Updates if it finds a cheaper way
- Stops when it reaches the goal

## Path Reconstruction

After finding the goal, we can trace back the path.

## Output

The code prints the found path step by step.
