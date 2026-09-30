//
//  SceneRegistry.swift
//  MachmanRender
//
//  Every scene the tool can draw, in --list order. A new area gets a Scenes/<area>.swift
//  enum with `static let all` and one line here.
//

enum SceneRegistry {
	static let all: [RenderScene] = InspectorScenes.all
}
